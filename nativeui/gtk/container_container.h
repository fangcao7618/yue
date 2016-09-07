// Copyright 2016 Cheng Zhao. All rights reserved.
// Use of this source code is governed by the license that can be found in the
// LICENSE file.

#ifndef NATIVEUI_GTK_CONTAINER_CONTAINER_H_
#define NATIVEUI_GTK_CONTAINER_CONTAINER_H_

#include <gtk/gtk.h>

// Custom GTK container type for nu::Container.

namespace nu {

class Container;

#define NU_TYPE_CONTAINER (nu_container_get_type ())
#define NU_CONTAINER(obj) (G_TYPE_CHECK_INSTANCE_CAST((obj), \
                           NU_TYPE_CONTAINER, NUContainer))

typedef struct _NUContainer        NUContainer;
typedef struct _NUContainerPrivate NUContainerPrivate;
typedef struct _NUContainerClass   NUContainerClass;

struct _NUContainer {
  GtkContainer container;
};

struct _NUContainerPrivate {
};

struct _NUContainerClass {
  GtkContainerClass parent_class;
};

GtkWidget* nu_container_new(Container* delegate);

}  // namespace nu

#endif  // NATIVEUI_GTK_CONTAINER_CONTAINER_H_
