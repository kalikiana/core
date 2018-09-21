/*
 Copyright (C) 2013-2018 Christian Dywan <christian@twotoats.de>

 This library is free software; you can redistribute it and/or
 modify it under the terms of the GNU Lesser General Public
 License as published by the Free Software Foundation; either
 version 2.1 of the License, or (at your option) any later version.

 See the file COPYING for the full license text.
*/

namespace Tabby {
    class SessionDatabase : Midori.Database {
        static SessionDatabase? _default = null;
        // Note: Using string instead of int64 because it's a hashable type
        HashTable<string, Midori.Browser> browsers;

        public static SessionDatabase get_default () throws Midori.DatabaseError {
            if (_default == null) {
                _default = new SessionDatabase ();
            }
            return _default;
        }

        SessionDatabase () throws Midori.DatabaseError {
            Object (path: "tabby.db", table: "tabs");
            init ();
            browsers = new HashTable<string, Midori.Browser> (str_hash, str_equal);
        }

        public async override List<Midori.DatabaseItem>? query (string? filter=null, int64 max_items=int64.MAX, Cancellable? cancellable=null) throws Midori.DatabaseError {
            string where = filter != null ? "AND (uri LIKE :filter OR title LIKE :filter)" : "";
            string sqlcmd = """
                SELECT id, uri, title, tstamp, session_id, closed FROM %s
                WHERE closed = 0 %s
                OR (session_id = (SELECT DISTINCT session_id from tabs ORDER BY tstamp DESC LIMIT 1))
                ORDER BY closed, tstamp DESC LIMIT :limit
                """.printf (table, where);
            var statement = prepare (sqlcmd,
                ":limit", typeof (int64), max_items);
            if (filter != null) {
                string real_filter = "%" + filter.replace (" ", "%") + "%";
                statement.bind (":filter", typeof (string), real_filter);
            }

            bool? fallback_to_closed = null;
            var items = new List<Midori.DatabaseItem> ();
            while (statement.step ()) {
                // Get only non-closed or only closed tabs
                bool closed = statement.get_int64 ("closed") == 1;
                if (fallback_to_closed == null) {
                    fallback_to_closed = closed;
                } else if (fallback_to_closed != closed) {
                    continue;
                }

                string uri = statement.get_string ("uri");
                string title = statement.get_string ("title");
                int64 date = statement.get_int64 ("tstamp");
                var item = new Midori.DatabaseItem (uri, title, date);
                item.database = this;
                item.id = statement.get_int64 ("id");
                item.set_data<int64> ("session_id", statement.get_int64 ("session_id"));
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
        }

        public async override bool insert (Midori.DatabaseItem item) throws Midori.DatabaseError {
            item.database = this;

            string sqlcmd = """
                INSERT INTO %s (crdate, tstamp, session_id, uri, title)
                VALUES (:crdate, :tstamp, :session_id, :uri, :title)
                """.printf (table);

            var statement = prepare (sqlcmd,
                ":crdate", typeof (int64), item.date,
                ":tstamp", typeof (int64), item.date,
                ":session_id", typeof (int64), item.get_data<int64> ("session_id"),
                ":uri", typeof (string), item.uri,
                ":title", typeof (string), item.title);
            if (statement.exec ()) {
                item.id = statement.row_id ();
                return true;
            }
            return false;
        }

        public async override bool update (Midori.DatabaseItem item) throws Midori.DatabaseError {
            string sqlcmd = """
                UPDATE %s SET uri = :uri, title = :title, tstamp = :tstamp, closed = 0 WHERE id = :id
                """.printf (table);
            try {
                var statement = prepare (sqlcmd,
                    ":id", typeof (int64), item.id,
                    ":uri", typeof (string), item.uri,
                    ":title", typeof (string), item.title,
                    ":tstamp", typeof (int64), new DateTime.now_local ().to_unix ());
                if (statement.exec ()) {
                    return true;
                }
            } catch (Midori.DatabaseError error) {
                critical ("Failed to update %s: %s", table, error.message);
            }
            return false;
        }

        public async override bool delete (Midori.DatabaseItem item) throws Midori.DatabaseError {
            // Delete in the context of a session means close, so we can re-open as well
            string sqlcmd = """
                UPDATE %s SET closed = 1, tstamp = :tstamp WHERE id = :id
                """.printf (table);
            var statement = prepare (sqlcmd,
                ":id", typeof (int64), item.id,
                ":tstamp", typeof (int64), new DateTime.now_local ().to_unix ());
            if (statement.exec ()) {
                return true;
            }
            return false;
        }

        int64 insert_session () {
            string sqlcmd = """
                INSERT INTO sessions (tstamp) VALUES (:tstamp)
                """;
            try {
                var statement = prepare (sqlcmd,
                    ":tstamp", typeof (int64), new DateTime.now_local ().to_unix ());
                statement.exec ();
                debug ("Added session: %s", statement.row_id ().to_string ());
                return statement.row_id ();
            } catch (Midori.DatabaseError error) {
                critical ("Failed to add session: %s", error.message);
            }
            return -1;
         }

        void update_session (int64 id, bool closed) {
            string sqlcmd = """
                UPDATE sessions SET closed=:closed, tstamp=:tstamp WHERE id = :id
                """;
            try {
                var statement = prepare (sqlcmd,
                    ":id", typeof (int64), id,
                    ":tstamp", typeof (int64), new DateTime.now_local ().to_unix (),
                    ":closed", typeof (int64), closed ? 1 : 0);
                statement.exec ();
            } catch (Midori.DatabaseError error) {
                critical ("Failed to update session: %s", error.message);
            }
        }

        public async void restore_session (Midori.App app) throws Midori.DatabaseError {
            // Keep track of new windows
            app.window_added.connect ((window) => {
                Timeout.add (1000, () => {
                    var browser = window as Midori.Browser;
                    // Don't track locked (app) or private windows
                    if (browser.is_locked || browser.web_context.is_ephemeral ()) {
                        return Source.REMOVE;
                    }
                    // Skip windows already in the session
                    if (browser.get_data<bool> ("tabby_connected")) {
                        return Source.REMOVE;
                    }
                    connect_browser (browser, insert_session ());
                    return Source.REMOVE;
                });
            });

            // Create first browser right away to claim the active_window
            // which is also going to receive whatever is opened via Application.open()
            var default_browser = new Midori.Browser (app);
            default_browser.show ();

            // Restore existing session(s) that weren't closed, or the last closed one
            foreach (var item in yield query ()) {
                Midori.Browser browser;
                int64 id = item.get_data<int64> ("session_id");
                if (default_browser != null) {
                    browser = default_browser;
                    default_browser = null;
                    connect_browser (browser, id);
                    foreach (var widget in browser.tabs.get_children ()) {
                        yield tab_added (widget as Midori.Tab, id);
                    }
                } else {
                    browser = browser_for_session (app, id);
                }
                var tab = new Midori.Tab (browser.tab, browser.web_context,
                                          item.uri, item.title);
                connect_tab (tab, item);
                browser.add (tab);
            }
        }

        Midori.Browser browser_for_session (Midori.App app, int64 id) {
            var browser = browsers.lookup (id.to_string ());
            if (browser == null) {
                debug ("Restoring session %s", id.to_string ());
                browser = new Midori.Browser (app);
                browser.show ();
                connect_browser (browser, id);
            }
            return browser;
        }

        void connect_browser (Midori.Browser browser, int64 id) {
            browsers.insert (id.to_string (), browser);
            browser.set_data<bool> ("tabby_connected", true);
            foreach (var widget in browser.tabs.get_children ()) {
                tab_added.begin (widget as Midori.Tab, id);
            }
            browser.tabs.add.connect ((widget) => { tab_added.begin (widget as Midori.Tab, id); });
            browser.tabs.remove.connect ((widget) => { tab_removed (widget as Midori.Tab); });
            browser.delete_event.connect ((event) => {
                debug ("Closing session %s", id.to_string ());
                foreach (var widget in browser.tabs.get_children ()) {
                    tab_removed (widget as Midori.Tab);
                }
                update_session (id, true);
                return false;
            });
        }

        void connect_tab (Midori.Tab tab, Midori.DatabaseItem item) {
            debug ("Connecting %s to session %s", item.uri, item.get_data<int64> ("session_id").to_string ());
            tab.set_data<Midori.DatabaseItem?> ("tabby-item", item);
            tab.notify["uri"].connect ((pspec) => { item.uri = tab.uri; update.begin (item); });
            tab.notify["title"].connect ((pspec) => { item.title = tab.title; });
        }

        bool tab_is_connected (Midori.Tab tab) {
            return tab.get_data<Midori.DatabaseItem?> ("tabby-item") != null;
        }

        async void tab_added (Midori.Tab tab, int64 id) {
            if (tab_is_connected (tab)) {
                return;
            }
            var item = new Midori.DatabaseItem (tab.display_uri, tab.display_title,
                                                new DateTime.now_local ().to_unix ());
            item.set_data<int64> ("session_id", id);
            try {
                yield insert (item);
                connect_tab (tab, item);
            } catch (Midori.DatabaseError error) {
                critical ("Failed add tab to session database: %s", error.message);
            }
        }

        void tab_removed (Midori.Tab tab) {
            var item = tab.get_data<Midori.DatabaseItem?> ("tabby-item");
            debug ("Trashing tab %s:%s", item.get_data<int64> ("session_id").to_string (), tab.display_uri);
            item.delete.begin ();
        }
    }

    public class Session : Peas.ExtensionBase, Midori.AppActivatable {
        public Midori.App app { owned get; set; }

        public void activate () {
            activate_async.begin ();
        }

        async void activate_async () {
            try {
                yield SessionDatabase.get_default ().restore_session (app);
            } catch (Midori.DatabaseError error) {
                critical ("Failed to restore session: %s", error.message);
            }
        }
    }
}

[ModuleInit]
public void peas_register_types(TypeModule module) {
    ((Peas.ObjectModule)module).register_extension_type (
        typeof (Midori.AppActivatable), typeof (Tabby.Session));

}
