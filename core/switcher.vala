/*
 Copyright (C) 2018 Christian Dywan <christian@twotoats.de>

 This library is free software; you can redistribute it and/or
 modify it under the terms of the GNU Lesser General Public
 License as published by the Free Software Foundation; either
 version 2.1 of the License, or (at your option) any later version.

 See the file COPYING for the full license text.
*/

namespace Midori {
    public class Switcher : Gtk.Box {
        HashTable<Gtk.Widget, Tally> buttons;
        public Gtk.Stack? stack { get; set; }
        public bool show_close_buttons { get; protected set; }

        construct {
            buttons = new HashTable<Gtk.Widget, Tally> (direct_hash, direct_equal);
            notify["stack"].connect ((pspec) => {
                stack.add.connect ((widget) => {
                    if (buttons.lookup (widget) == null && widget is Tab) {
                        var button = new Tally ((Tab)widget);
                        buttons.insert (widget, button);
                        button.active = stack.visible_child == widget;
                        button.clicked.connect (() => {
                            stack.visible_child = widget;
                        });
                        show_close_buttons = buttons.size () > 1;
                        button.show_close = show_close_buttons;
                        bind_property ("show-close-buttons", button, "show-close");
                        add (button);
                    }
                });
                stack.notify["visible-child"].connect (visible_child_changed);
                stack.remove.connect ((widget) => {
                    buttons.take (widget).destroy ();
                    show_close_buttons = buttons.size () > 1;
                });
            });
        }

        void visible_child_changed (ParamSpec pspec) {
            var button = buttons.lookup (stack.visible_child);
            if (button != null) {
                foreach (var b in get_children ()) {
                    ((Tally)b).active = (b == button);
                    if (button.active) {
                        // Autoscroll active button into view
                        var scrolled = (Gtk.ScrolledWindow)get_ancestor (typeof (Gtk.ScrolledWindow));
                        if (scrolled != null) {
                            // Schedule an idle so allocation will be set
                            Idle.add (() => {
                                var adjustment = scrolled.hadjustment;
                                Gtk.Allocation alloc;
                                button.get_allocation (out alloc);
                                adjustment.value = alloc.x;
                                return Source.REMOVE;
                            });
                        }
                    }
                }
            }
        }
    }
}
