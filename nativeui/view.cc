// Copyright 2016 Cheng Zhao. All rights reserved.
// Use of this source code is governed by the license that can be found in the
// LICENSE file.

#include "nativeui/view.h"

#include <utility>

#include "base/strings/string_util.h"
#include "nativeui/container.h"
#include "nativeui/cursor.h"
#include "nativeui/gfx/font.h"
#include "nativeui/state.h"
#include "nativeui/util/yoga_util.h"
#include "nativeui/window.h"
#include "third_party/yoga/yoga/YGNodePrint.h"
#include "third_party/yoga/yoga/Yoga.h"

namespace nu {

namespace {

// Convert case to lower and remove non-ASCII characters.
std::string ParseName(const std::string& name) {
  std::string parsed;
  parsed.reserve(name.size());
  for (char c : name) {
    if (base::IsAsciiAlpha(c))
      parsed.push_back(base::ToLowerASCII(c));
  }
  return parsed;
}

}  // namespace

// static
const char View::kClassName[] = "View";

View::View() : view_(nullptr) {
  // Create node with the default yoga config.
  yoga_config_ = YGConfigNew();
  YGConfigCopy(yoga_config_, State::GetCurrent()->yoga_config());
  node_ = YGNodeNewWithConfig(yoga_config_);
}

View::~View() {
  PlatformDestroy();

  // Free yoga config and node.
  YGNodeFree(node_);
  YGConfigFree(yoga_config_);
}

const char* View::GetClassName() const {
  return kClassName;
}

void View::SetVisible(bool visible) {
  if (visible == IsVisible())
    return;
  PlatformSetVisible(visible);
  YGNodeStyleSetDisplay(node_, visible ? YGDisplayFlex : YGDisplayNone);
  Layout();
}

void View::Layout() {
  // By default just make parent do layout.
  if (GetParent() && GetParent()->IsContainer())
    static_cast<Container*>(GetParent())->Layout();
}

int View::StartDrag(std::vector<Clipboard::Data> data, int operations) {
  return StartDragWithImage(std::move(data), operations, nullptr);
}

void View::SetCursor(Cursor* cursor) {
  if (cursor_.get() == cursor)
    return;
  PlatformSetCursor(cursor);
  cursor_ = cursor;
}

void View::SetFont(Font* font) {
  if (font_.get() == font)
    return;
  PlatformSetFont(font);
  font_ = font;
  UpdateDefaultStyle();
}

void View::UpdateDefaultStyle() {
  SizeF min_size = GetMinimumSize();
  YGNodeStyleSetMinWidth(node_, min_size.width());
  YGNodeStyleSetMinHeight(node_, min_size.height());
  Layout();
}

void View::SetStyleProperty(const std::string& name, const std::string& value) {
  std::string key(ParseName(name));
  if (key == "color")
    SetColor(Color(value));
  else if (key == "backgroundcolor")
    SetBackgroundColor(Color(value));
  else
    SetYogaProperty(node_, key, value);
}

void View::SetStyleProperty(const std::string& name, float value) {
  SetYogaProperty(node_, ParseName(name), value);
}

std::string View::GetComputedLayout() const {
  std::string result;
  auto options = static_cast<YGPrintOptions>(YGPrintOptionsLayout |
                                             YGPrintOptionsStyle |
                                             YGPrintOptionsChildren);
  facebook::yoga::YGNodeToString(&result, node_, options, 0);
  return result;
}

SizeF View::GetMinimumSize() const {
  return SizeF();
}

void View::SetParent(View* parent) {
  if (parent) {
    window_ = parent->window_;
    YGConfigCopy(yoga_config_, parent->yoga_config_);
  } else {
    window_ = nullptr;
  }
  parent_ = parent;
}

void View::BecomeContentView(Window* window) {
  if (window) {
    window_ = window;
    YGConfigCopy(yoga_config_, window->GetYogaConfig());
  } else {
    window_ = nullptr;
  }
  parent_ = nullptr;
}

bool View::IsContainer() const {
  return false;
}

void View::OnSizeChanged() {
  on_size_changed.Emit(this);
}

}  // namespace nu
