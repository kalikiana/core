/*
 Copyright (C) 2013-2018 Christian Dywan <christian@twotoats.de>

 This library is free software; you can redistribute it and/or
 modify it under the terms of the GNU Lesser General Public
 License as published by the Free Software Foundation; either
 version 2.1 of the License, or (at your option) any later version.

 See the file COPYING for the full license text.
*/

namespace Bookmarks {
    class BookmarksDatabase : Midori.Database {
        static BookmarksDatabase? _default = null;
        public static BookmarksDatabase get_default () throws Midori.DatabaseError {
            if (_default == null) {
                _default = new BookmarksDatabase ();
            }
            return _default;
        }

        BookmarksDatabase () throws Midori.DatabaseError {
            Object (path: "bookmarks.db");
            init ();
        }

        public async override Midori.DatabaseItem? lookup (string uri) throws Midori.DatabaseError {
            string sqlcmd = """
                SELECT id, title FROM %s WHERE uri = :uri LIMIT 1
                """.printf (table);
            var statement = prepare (sqlcmd,
                ":uri", typeof (string), uri);
            if (statement.step ()) {
                string title = statement.get_string ("title");
                var item = new Midori.DatabaseItem (uri, title);
                item.database = this;
                item.id = statement.get_int64 ("id");
                return item;
            }
            return null;
        }

        public async override List<Midori.DatabaseItem>? query (string? filter=null, int64 max_items=15, Cancellable? cancellable=null) throws Midori.DatabaseError {
            string where = filter != null ? "WHERE uri LIKE :filter OR title LIKE :filter" : "";
            string sqlcmd = """
                SELECT id, uri, title, visit_count AS ct FROM %s
                %s
                WHERE uri <> ''
                GROUP BY uri
                ORDER BY ct DESC LIMIT :limit
                """.printf (table, where);

            try {
                var statement = prepare (sqlcmd,
                    ":limit", typeof (int64), max_items);
                if (filter != null) {
                    string real_filter = "%" + filter.replace (" ", "%") + "%";
                    statement.bind (":filter", typeof (string), real_filter);
                }

                var items = new List<Midori.DatabaseItem> ();
                while (statement.step ()) {
                    string uri = statement.get_string ("uri");
                    string title = statement.get_string ("title");
                    var item = new Midori.DatabaseItem (uri, title);
                    item.database = this;
                    item.id = statement.get_int64 ("id");
                    items.append (item);

                    uint src = Idle.add (query.callback);
                    yield;
                    Source.remove (src);

                    if (cancellable != null && cancellable.is_cancelled ())
                        return null;
                }
                if (cancellable != null && cancellable.is_cancelled ())
                    return null;
                return items;
            } catch (Midori.DatabaseError error) {
                critical ("Failed to query bookmarks: %s", error.message);
            }
            return null;
        }

        public async override bool update (Midori.DatabaseItem item) throws Midori.DatabaseError {
            string sqlcmd = """
                UPDATE %s SET uri = :uri, title = :title WHERE id = :id
                """.printf (table);
            try {
                var statement = prepare (sqlcmd,
                    ":id", typeof (int64), item.id,
                    ":uri", typeof (string), item.uri,
                    ":title", typeof (string), item.title);
                if (statement.exec ()) {
                    // FIXME: items_changed (_items.index (item), 1, 0);
                    return true;
                }
            } catch (Error error) {
                critical ("Failed to update %s: %s", table, error.message);
            }
            return false;
        }

        public async override bool insert (Midori.DatabaseItem item) throws Midori.DatabaseError {
            item.database = this;

            string sqlcmd = """
                INSERT INTO %s (uri, title) VALUES (:uri, :title)
                """.printf (table);
            var statement = prepare (sqlcmd,
                ":uri", typeof (string), item.uri,
                ":title", typeof (string), item.title);
            if (statement.exec ()) {
                item.id = statement.row_id ();
                items_changed (get_n_items (), 1, 0);
                return true;
            }
            return false;
        }
    }

    [GtkTemplate (ui = "/ui/bookmarks-button.ui")]
    public class Button : Gtk.Button {
        [GtkChild]
        Gtk.Popover popover;
        [GtkChild]
        Gtk.Entry entry_title;
        [GtkChild]
        Gtk.Button button_remove;

        Midori.Browser browser;

        construct {
            popover.relative_to = this;
            entry_title.changed.connect (() => {
                var item = browser.tab.get_data<Midori.DatabaseItem?> ("bookmarks-item");
                if (item != null) {
                    item.title = entry_title.text;
                }
            });
            button_remove.clicked.connect (() => {
                popover.hide ();
                var item = browser.tab.get_data<Midori.DatabaseItem?> ("bookmarks-item");
                item.delete.begin ();
                browser.tab.set_data<Midori.DatabaseItem?> ("bookmarks-item", null);
            });
        }

        async Midori.DatabaseItem item_for_tab (Midori.Tab tab) {
            var item = tab.get_data<Midori.DatabaseItem?> ("bookmarks-item");
            if (item == null) {
                try {
                    item = yield BookmarksDatabase.get_default ().lookup (tab.display_uri);
                } catch (Midori.DatabaseError error) {
                    critical ("Failed to lookup %s in bookmarks database: %s", tab.display_uri, error.message);
                }
                if (item == null) {
                    item = new Midori.DatabaseItem (tab.display_uri, tab.display_title);
                    try {
                        yield BookmarksDatabase.get_default ().insert (item);
                    } catch (Midori.DatabaseError error) {
                        critical ("Failed to add %s to bookmarks database: %s", item.uri, error.message);
                    }
                }
                entry_title.text = item.title;
                tab.set_data<Midori.DatabaseItem?> ("bookmarks-item", item);
            }
            return item;
        }

        public virtual signal void add_bookmark () {
            var tab = browser.tab;
            item_for_tab.begin (tab);
            popover.show ();
        }

        public Button (Midori.Browser browser) {
            this.browser = browser;

            var action = new SimpleAction ("bookmark-add", null);
            action.activate.connect (bookmark_add_activated);
            browser.notify["uri"].connect (() => {
                action.set_enabled (browser.uri.has_prefix ("http"));
            });
            browser.add_action (action);
            browser.application.set_accels_for_action ("win.bookmark-add", { "<Primary>d" });
        }

        void bookmark_add_activated () {
            add_bookmark ();
        }
    }

    public class Frontend : Object, Midori.BrowserActivatable {
        public Midori.Browser browser { owned get; set; }

        Gtk.Widget create_button (Object item) {
            var bookmark = item as Midori.DatabaseItem;
            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
            box.hexpand = true;
            var label = new Gtk.Label (bookmark.title ?? bookmark.uri);
            label.ellipsize = Pango.EllipsizeMode.END;
            // As per docs, when ellipsized and expanded max width is the minimum
            label.width_chars = 8;
            label.max_width_chars = 500;
            box.add (label);
            var icon = new Midori.Favicon ();
            string layout = Gtk.Settings.get_default ().gtk_decoration_layout;
            if (layout.index_of ("c") < layout.index_of (":")) {
                box.pack_start (icon);
            } else {
                box.pack_end (icon);
            }
            var button = new Gtk.Button ();
            button.relief = Gtk.ReliefStyle.NONE;
            button.focus_on_click = false;
            button.add (box);
            if (bookmark.uri != null && bookmark.uri != "") {
                box.tooltip_text = bookmark.uri;
                icon.uri = bookmark.uri;
                button.clicked.connect (() => { browser.tab.load_uri (bookmark.uri); });
            /* FIXME: } else {
                icon.gicon = new ThemedIcon.with_default_fallbacks ("folder-symbolic"); */
            }
            button.show_all ();
            return button;
        }

        public void activate () {
            // No bookmarks in app mode
            if (browser.is_locked) {
                return;
            }

            browser.add_button (new Button (browser));

            try {
                var toolbar = new Gtk.FlowBox ();
                toolbar.get_style_context ().add_class ("inline-toolbar");
                // To get horizontal, we need to use vertical
                toolbar.orientation = Gtk.Orientation.VERTICAL;
                toolbar.bind_model (BookmarksDatabase.get_default (), create_button);
                toolbar.show ();
                var scrolled = new Gtk.ScrolledWindow (null, null);
                scrolled.hscrollbar_policy = Gtk.PolicyType.EXTERNAL;
                scrolled.vscrollbar_policy = Gtk.PolicyType.NEVER;
                scrolled.add (toolbar);
                scrolled.halign = Gtk.Align.FILL;
                scrolled.valign = Gtk.Align.START;
                browser.overlay.add_overlay (scrolled);
                // Only show bookmarks in new tab
                browser.notify["uri"].connect (() => {
                    scrolled.visible = browser.uri.has_prefix ("internal");
                });
            } catch (Midori.DatabaseError error) {
                critical ("Failed to add bookmarks toolbar: %s", error.message);
            }

            try {
                var panel = new Gtk.ListBox ();
                panel.bind_model (BookmarksDatabase.get_default (), create_button);
                panel.show ();
                var scrolled = new Gtk.ScrolledWindow (null, null);
                scrolled.hscrollbar_policy = Gtk.PolicyType.EXTERNAL;
                scrolled.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
                scrolled.add (panel);
                scrolled.show ();
                browser.add_panel (scrolled);
                scrolled.parent.child_set (scrolled, "title", _("Bookmarks"), "icon-name", "user-bookmarks-symbolic");
            } catch (Midori.DatabaseError error) {
                critical ("Failed to add bookmarks panel: %s", error.message);
            }

            try {
                var panel = new Gtk.ListBox ();
                panel.bind_model (Midori.HistoryDatabase.get_default (), create_button);
                panel.show ();
                var scrolled = new Gtk.ScrolledWindow (null, null);
                scrolled.hscrollbar_policy = Gtk.PolicyType.EXTERNAL;
                scrolled.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
                scrolled.add (panel);
                scrolled.show ();
                browser.add_panel (scrolled);
                scrolled.parent.child_set (scrolled, "title", _("History"), "icon-name", "document-open-recent-symbolic");
            } catch (Midori.DatabaseError error) {
                critical ("Failed to add bookmarks panel: %s", error.message);
            }
        }
    }

    public class Completion : Peas.ExtensionBase, Midori.CompletionActivatable {
        public Midori.Completion completion { owned get; set; }

        public void activate () {
            try {
                completion.add (BookmarksDatabase.get_default ());
            } catch (Midori.DatabaseError error) {
                critical ("Failed to add bookmarks completion: %s", error.message);
            }
        }
    }
}

[ModuleInit]
public void peas_register_types(TypeModule module) {
    ((Peas.ObjectModule)module).register_extension_type (
        typeof (Midori.BrowserActivatable), typeof (Bookmarks.Frontend));
    ((Peas.ObjectModule)module).register_extension_type (
        typeof (Midori.CompletionActivatable), typeof (Bookmarks.Completion));

}
