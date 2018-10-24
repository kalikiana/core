/*
 Copyright (C) 2018 Christian Dywan <christian@twotoats.de>

 This library is free software; you can redistribute it and/or
 modify it under the terms of the GNU Lesser General Public
 License as published by the Free Software Foundation; either
 version 2.1 of the License, or (at your option) any later version.

 See the file COPYING for the full license text.
*/

namespace Midori {
    public const DebugKey[] keys = {
        { "historydatabase", DebugFlags.HISTORY },
    };

    public enum DebugFlags {
        NONE,
        HISTORY,
    }

    public interface Loggable : Object {
        public string domain { owned get {
            string? _domain = get_data<string> ("midori-domain");
            if (_domain == null) {
                _domain = get_type ().name ().substring (6, -1).down ();
                set_data<string> ("midori-domain", _domain);
            }
            return _domain;
        } }

        public bool logging { owned get {
            bool? _logging = get_data<bool?> ("midori-logging");
            if (_logging == null) {
                uint flag = int.MAX;
                foreach (var key in keys) {
                    if (key.key == domain) {
                        flag = key.value;
                    }
                }
                string debug_string = Environment.get_variable ("G_MESSAGES_DEBUG");
                uint flags = parse_debug_string (debug_string, keys);
                _logging = (flags & flag) != 0;
                set_data<bool?> ("midori-logging", _logging);
            }
            return _logging;
        } }

        public void debug (string format, ...) {
            logv (domain, LogLevelFlags.LEVEL_DEBUG, format, va_list ());
        }
    }
}
