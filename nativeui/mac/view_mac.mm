// Copyright 2016 Cheng Zhao. All rights reserved.
// Use of this source code is governed by the license that can be found in the
// LICENSE file.

#include "nativeui/mac/nu_view.h"

#include "nativeui/browser.h"
#include "nativeui/container.h"
#include "nativeui/cursor.h"
#include "nativeui/gfx/font.h"
#include "nativeui/gfx/geometry/point_conversions.h"
#include "nativeui/gfx/geometry/rect_conversions.h"
#include "nativeui/gfx/mac/painter_mac.h"
#include "nativeui/mac/drag_drop/data_provider.h"
#include "nativeui/mac/drag_drop/nested_run_loop.h"
#include "nativeui/mac/events_handler.h"
#include "nativeui/mac/mouse_capture.h"
#include "nativeui/mac/nu_private.h"

namespace nu {

namespace {

// There is no way to know when another application has installed an event
// monitor, we have to assume only current app can capture view.
View* g_captured_view = nullptr;

}  // namespace

void View::PlatformDestroy() {
  if (IsNUView(view_)) {
    // The view may be referenced after this class gets destroyed.
    NUPrivate* priv = [view_ nuPrivate];
    priv->shell = nullptr;
  }
  [view_ release];
}

void View::TakeOverView(NativeView view) {
  view_ = view;

  if (!IsNUView(view))
    return;

  // Install events handle for the view's class.
  Class cl = [view class];
  if (!NUViewMethodsInstalled(cl)) {
    InstallNUViewMethods(cl);
    // TODO(zcbenz): Lazily install the event hooks.
    if (GetClassName() != Browser::kClassName) {
      // WKWebView does not like having mouse event handlers installed.
      AddMouseEventHandlerToClass(cl);
    }
    AddKeyEventHandlerToClass(cl);
    AddDragDropHandlerToClass(cl);
  }

  // Initialize private bits of the view.
  NUPrivate* priv = [view nuPrivate];
  priv->shell = this;

  // Set the |focusable| property to the parent class's default one.
  SEL cmd = @selector(acceptsFirstResponder);
  auto super_impl = reinterpret_cast<BOOL (*)(NSView*, SEL)>(
      [[view superclass] instanceMethodForSelector:cmd]);
  priv->focusable = super_impl(view, cmd);

  // Set the |draggable| property to the parent class's default one.
  cmd = @selector(mouseDownCanMoveWindow);
  super_impl = reinterpret_cast<BOOL (*)(NSView*, SEL)>(
      [[view superclass] instanceMethodForSelector:cmd]);
  priv->draggable = super_impl(view, cmd);

  // Install event tracking area.
  // TODO(zcbenz): Lazily install the event hooks.
  [view enableTracking];
}

void View::SetBounds(const RectF& bounds) {
  NSRect frame = bounds.ToCGRect();
  [view_ setFrame:frame];
  // Calling setFrame manually does not trigger resizeSubviewsWithOldSize.
  [view_ resizeSubviewsWithOldSize:frame.size];
}

Vector2dF View::OffsetFromView(const View* from) const {
  NSPoint point = [view_ convertPoint:NSZeroPoint toView:from->view_];
  return Vector2dF(point.x, point.y);
}

Vector2dF View::OffsetFromWindow() const {
  NSPoint point = [view_ convertPoint:NSZeroPoint toView:nil];
  return Vector2dF(point.x, point.y);
}

RectF View::GetBounds() const {
  return RectF([view_ frame]);
}

void View::SetPixelBounds(const Rect& bounds) {
  SetBounds(RectF(bounds));
}

Rect View::GetPixelBounds() const {
  return ToNearestRect(GetBounds());
}

void View::SchedulePaint() {
  [view_ setNeedsDisplay:YES];
}

void View::SchedulePaintRect(const RectF& rect) {
  [view_ setNeedsDisplayInRect:rect.ToCGRect()];
}

void View::PlatformSetVisible(bool visible) {
  [view_ setHidden:!visible];
}

bool View::IsVisible() const {
  return ![view_ isHidden];
}

bool View::IsTreeVisible() const {
  return ![view_ isHiddenOrHasHiddenAncestor];
}

void View::SetEnabled(bool enable) {
  [view_ setNUEnabled:enable];
}

bool View::IsEnabled() const {
  return [view_ isNUEnabled];
}

void View::Focus() {
  if (view_.window && IsFocusable())
    [view_.window makeFirstResponder:view_];
}

bool View::HasFocus() const {
  if (view_.window)
    return view_.window.firstResponder == view_;
  else
    return false;
}

void View::SetFocusable(bool focusable) {
  NUPrivate* priv = [view_ nuPrivate];
  priv->focusable = focusable;
}

bool View::IsFocusable() const {
  return [view_ acceptsFirstResponder];
}

void View::SetCapture() {
  if (g_captured_view)
    g_captured_view->ReleaseCapture();

  NUPrivate* priv = [view_ nuPrivate];
  priv->mouse_capture.reset(new MouseCapture(this));
  g_captured_view = this;
}

void View::ReleaseCapture() {
  if (g_captured_view != this)
    return;

  NUPrivate* priv = [view_ nuPrivate];
  priv->mouse_capture.reset();
  g_captured_view = nullptr;
  on_capture_lost.Emit(this);
}

bool View::HasCapture() const {
  return g_captured_view == this;
}

void View::SetMouseDownCanMoveWindow(bool yes) {
  NUPrivate* priv = [view_ nuPrivate];
  priv->draggable = yes;

  // AppKit will not update its cache of mouseDownCanMoveWindow unless something
  // changes.
  [[view_ window] setMovableByWindowBackground:NO];
  [[view_ window] setMovableByWindowBackground:YES];
}

bool View::IsMouseDownCanMoveWindow() const {
  return [view_ mouseDownCanMoveWindow];
}

int View::StartDragWithImage(
    std::vector<Clipboard::Data> data, int operations, Image* drag_image) {
  // Cocoa throws exception without data in drag session.
  if (data.empty())
    return DRAG_OPERATION_NONE;

  NUPrivate* priv = [view_ nuPrivate];
  priv->supported_drag_operation = operations;
  priv->data_source.reset([[DataProvider alloc] initWithData:std::move(data)]);

  // Release capture before beginning the dragging session. Capture may have
  // been acquired on the mouseDown, but capture is not required during the
  // dragging session and the mouseUp that would release it will be suppressed.
  ReleaseCapture();

  // Synthesize an event for dragging, since we can't be sure that
  // [NSApp currentEvent] will return a valid dragging event.
  NSWindow* window = [view_ window];
  NSPoint position = [window mouseLocationOutsideOfEventStream];
  NSTimeInterval event_time = [[NSApp currentEvent] timestamp];
  NSEvent* event = [NSEvent mouseEventWithType:NSLeftMouseDragged
                                      location:position
                                 modifierFlags:NSLeftMouseDraggedMask
                                     timestamp:event_time
                                  windowNumber:[window windowNumber]
                                       context:nil
                                   eventNumber:0
                                    clickCount:1
                                      pressure:1.0];

  base::scoped_nsobject<NSPasteboardItem> item([[NSPasteboardItem alloc] init]);
  [item setDataProvider:priv->data_source
               forTypes:[[priv->data_source pasteboard] types]];

  base::scoped_nsobject<NSDraggingItem> drag_item(
      [[NSDraggingItem alloc] initWithPasteboardWriter:item.get()]);

  // Set drag image.
  if (drag_image) {
    NSImage* image = drag_image->GetNative();
    NSRect dragging_frame = NSMakeRect([event locationInWindow].x, 0,
                                       [image size].width, [image size].height);
    [drag_item setDraggingFrame:dragging_frame contents:image];
  } else {
    [drag_item setDraggingFrame:NSMakeRect(0, 0, 100, 100) contents:nil];
  }

  [view_ beginDraggingSessionWithItems:@[drag_item.get()]
                                 event:event
                                source:(id<NSDraggingSource>)view_];

  // Since Drag and drop is asynchronous on Mac, we need to spin a nested run
  // loop for consistency with other platforms.
  NestedRunLoop run_loop;
  priv->quit_dragging = [&run_loop, &priv]() {
    run_loop.Quit();
    priv->quit_dragging = nullptr;
  };
  run_loop.Run();
  return priv->drag_result;
}

void View::CancelDrag() {
  NUPrivate* priv = [view_ nuPrivate];
  if (priv->quit_dragging)
    priv->quit_dragging();
}

bool View::IsDragging() const {
  return !![view_ nuPrivate]->quit_dragging;
}

void View::RegisterDraggedTypes(std::set<Clipboard::Data::Type> types) {
  NSMutableArray* newTypes = [NSMutableArray array];
  for (auto type : types) {
    switch (type) {
      case Clipboard::Data::Type::Text:
        [newTypes addObject:NSPasteboardTypeString];
        break;
      case Clipboard::Data::Type::HTML:
        [newTypes addObject:NSHTMLPboardType];
        [newTypes addObject:NSRTFPboardType];
        break;
      case Clipboard::Data::Type::Image:
        [newTypes addObject:NSPasteboardTypeTIFF];
        break;
      case Clipboard::Data::Type::FilePaths:
        [newTypes addObject:NSFilenamesPboardType];
        break;
      default:
        break;
    }
  }
  [view_ registerForDraggedTypes:newTypes];
}

void View::PlatformSetCursor(Cursor* cursor) {
  if (IsNUView(view_)) {
    if (cursor)
      [view_ nuPrivate]->cursor.reset([cursor->GetNative() retain]);
    else
      [view_ nuPrivate]->cursor.reset();
  }
}

void View::PlatformSetFont(Font* font) {
  if (IsNUView(view_))
    [view_ setNUFont:font];
}

void View::SetColor(Color color) {
  if (IsNUView(view_))
    [view_ setNUColor:color];
}

void View::SetBackgroundColor(Color color) {
  if (IsNUView(view_))
    [view_ setNUBackgroundColor:color];
}

void View::SetWantsLayer(bool wants) {
  [view_ nuPrivate]->wants_layer = wants;
  [view_ setWantsLayer:wants];
}

bool View::WantsLayer() const {
  return [view_ wantsLayer];
}

}  // namespace nu
