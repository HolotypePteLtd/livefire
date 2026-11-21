import 'dart:ffi';

import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart';

bool _libraryPinned = false;

Database openSqliteDatabase(String path) {
  if (!_libraryPinned) {
    sqlite_open.open.overrideForAll(_loadSqlite);
    _libraryPinned = true;
  }
  return sqlite3.open(path);
}

// Runtime images ship libsqlite3.so.0, and macOS ships libsqlite3.dylib.
DynamicLibrary _loadSqlite() {
  for (final name in ['libsqlite3.so', 'libsqlite3.so.0', 'libsqlite3.dylib']) {
    try {
      return DynamicLibrary.open(name);
    } on ArgumentError {
      continue;
    }
  }
  return DynamicLibrary.open('libsqlite3.so');
}
