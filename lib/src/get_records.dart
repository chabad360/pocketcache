import 'dart:async';
import 'dart:convert';
import 'dart:core';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:sqlite3/common.dart';
import 'package:state_groups/state_groups.dart';

import 'pocketbase_offline_cache_base.dart';

extension ListWrapper on PbOfflineCache {
  Future<List<Map<String, dynamic>>> getRecords(
    String collectionName, {
    int maxItems = defaultMaxItems,
    int page = 1,
    (String, List<Object?>)? where,
    QuerySource source = QuerySource.any,
    List<(String column, bool descending)> sort = const <(String, bool descending)>[],
    Map<String, dynamic>? startAfter,
    List<String> expand = const <String>[],
  }) async {
    if (source != QuerySource.server && (!remoteAccessible || source == QuerySource.cache)) {
      final Set<String> columnNames = await getColumnNames(dbIsolate, collectionName);

      if (columnNames.isNotEmpty) {
        final List<Map<String, dynamic>> results = await getFromLocalDb(dbIsolate, collectionName,
            maxItems: maxItems,
            page: page,
            filter: where,
            startAfter: startAfter,
            sort: sort,
            columnNames: columnNames);

        final List<Map<String, dynamic>> dataToReturn = <Map<String, dynamic>>[];
        for (final Map<String, dynamic> row in results) {
          final Map<String, dynamic> entryToInsert = <String, dynamic>{};
          for (final MapEntry<String, dynamic> data in row.entries) {
            if (data.key.startsWith("_offline_bool_")) {
              entryToInsert[data.key.substring(14)] = data.value == 1 ? true : false;
            } else if (data.key.startsWith("_offline_json_")) {
              entryToInsert[data.key.substring(14)] = jsonDecode(data.value);
            } else {
              entryToInsert[data.key] = data.value;
            }
          }
          if (expand.isNotEmpty) {
            final Map<String, List<Map<String, dynamic>>> expansions = <String, List<Map<String, dynamic>>>{};
            for (final String expandCollection in expand) {
              late final List<String> foreignKeys;
              if (entryToInsert[expandCollection] is List<dynamic>) {
                foreignKeys = List<String>.from(entryToInsert[expandCollection]);
              } else if (entryToInsert[expandCollection] is String) {
                foreignKeys = <String>[entryToInsert[expandCollection]];
              } else {
                logger.w(
                    "Unable to expand '$expandCollection' for ${row["id"]}, type: ${entryToInsert[expandCollection].runtimeType}");
                continue;
              }
              final List<Map<String, dynamic>> expanded = await getRecords(expandCollection,
                  where: ("id IN (${foreignKeys.map((_) => "?").join(", ")})", foreignKeys), source: QuerySource.cache);
              expansions[expandCollection] = expanded;
            }
            if (expansions.isNotEmpty) {
              entryToInsert["expand"] = expansions;
            }
          }
          dataToReturn.add(entryToInsert);
        }
        return dataToReturn;
      }

      return <Map<String, dynamic>>[];
    }

    try {
      final List<RecordModel> records = (await pb.collection(collectionName).getList(
              page: page,
              perPage: maxItems,
              skipTotal: true,
              filter: makePbFilter(where, sort: sort, startAfter: startAfter),
              sort: makeSortFilter(sort),
              expand: expand.join(",")))
          .items;

      if (await dbIsolate.enabled()) {
        final Map<String, dynamic>? lastSyncTime = (await dbIsolate.select(
          "SELECT last_update FROM _last_sync_times WHERE table_name=?",
          <String>[collectionName],
        ))
            .firstOrNull;

        if (lastSyncTime == null) {
          DateTime? newLastSyncTime;

          for (final RecordModel model in records) {
            final DateTime? time = DateTime.tryParse(model.get("updated"))?.toUtc();
            if (time == null) {
              logger.e("Unable to parse time ${model.get<String>("updated")}");
            }
            if (time != null && (newLastSyncTime == null || time.isAfter(newLastSyncTime))) {
              newLastSyncTime = time;
            }
          }

          if (newLastSyncTime != null) {
            unawaited(dbIsolate.execute("INSERT OR REPLACE INTO _last_sync_times(table_name, last_update) VALUES(?, ?)",
                <dynamic>[collectionName, newLastSyncTime.toString()]));
          }
        }
      }

      if (records.isNotEmpty) {
        unawaited(insertRecordsIntoLocalDb(collectionName, records, logger,
            indexInstructions: indexInstructions, stackTrace: StackTrace.current));
      }

      final List<Map<String, dynamic>> data = <Map<String, dynamic>>[];

      for (final RecordModel record in records) {
        final Map<String, dynamic> entry = Map<String, dynamic>.from(record.data);

        final Map<String, dynamic>? expansions = record.get("expand");

        if (expansions != null) {
          for (final String key in expansions.keys) {
            final List<Map<String, dynamic>> items = <Map<String, dynamic>>[
              ...(expansions[key] as List<Map<String, dynamic>>)
            ];
            unawaited(insertRawDataIntoLocalDb(key, items, logger, stackTrace: StackTrace.current)
                .onError((Object? e, StackTrace s) => debugPrint("$e\n$s")));
          }
        }
        data.add(entry);
      }

      return data;
    } on ClientException catch (e) {
      if (!e.isNetworkError()) {
        logger
            .e("$e: filter: ${makePbFilter(where, sort: sort, startAfter: startAfter)}, sort: ${makeSortFilter(sort)}");
        rethrow;
      }
      if (source == QuerySource.any) {
        return getRecords(collectionName,
            where: where, sort: sort, maxItems: maxItems, startAfter: startAfter, source: QuerySource.cache);
      } else {
        rethrow;
      }
    }
  }

  Future<void> insertRecordsIntoLocalDb(String collectionName, List<RecordModel> records, Logger logger,
      {Map<String, List<(String name, bool unique, List<String> columns)>> indexInstructions =
          const <String, List<(String, bool, List<String>)>>{},
      String? overrideDownloadTime,
      StackTrace? stackTrace,
      bool allowRecurse = true}) async {
    if (!(await dbIsolate.enabled()) || records.isEmpty) {
      return;
    }

    if (!isTest() && records.first.collectionName != "") {
      assert(collectionName == records.first.collectionName,
          "Collection name mismatch given: $collectionName, record's collection: ${records.first.collectionName}");
    }

    final List<Map<String, dynamic>> dataToSave = <Map<String, dynamic>>[];
    final Map<String, List<RecordModel>> expandRecords = <String, List<RecordModel>>{};

    for (final RecordModel record in records) {
      final Map<String, dynamic> recordMap = Map<String, dynamic>.from(record.data);
      dataToSave.add(recordMap);

      for (final List<RecordModel> entry in record.expand.values) {
        for (final RecordModel model in entry) {
          final String? collection = model.data["collectionName"];

          if (collection == null) {
            debugPrint("Unable to find collection name!");
          } else {
            if (!expandRecords.containsKey(collection)) {
              expandRecords[collection] = <RecordModel>[];
            }
            expandRecords[collection]!.add(model);
          }
        }
      }
    }

    if (expandRecords.isNotEmpty) {
      if (allowRecurse) {
        for (final MapEntry<String, List<RecordModel>> data in expandRecords.entries) {
          unawaited(insertRecordsIntoLocalDb(data.key, data.value, logger, allowRecurse: false));
        }
      } else {
        debugPrint("Found expand records but recursion not allowed!");
      }
    }

    for (final RecordModel record in records) {
      broadcastToListeners("pocketcache/pre-local-update", (collectionName, record));
    }

    return insertRawDataIntoLocalDb(collectionName, dataToSave, logger);
  }

  Future<void> insertRawDataIntoLocalDb(String collectionName, List<Map<String, dynamic>> dataToSave, Logger logger,
      {Map<String, List<(String name, bool unique, List<String> columns)>> indexInstructions =
          const <String, List<(String, bool, List<String>)>>{},
      String? overrideDownloadTime,
      StackTrace? stackTrace}) async {
    if (!(await dbIsolate.enabled()) || dataToSave.isEmpty) {
      return;
    }

    for (final Map<String, dynamic> data in dataToSave) {
      data.remove("collectionName");
      data.remove("collectionId");
      data.remove("expand");
    }

    await tableExistsLock.synchronized(() async {
      if (!(await tableExists(dbIsolate, collectionName))) {
        final StringBuffer schema = StringBuffer("id TEXT PRIMARY KEY, created TEXT, updated TEXT, _downloaded TEXT");
        final Set<String> tableKeys = <String>{"id", "created", "updated", "_downloaded"};

        for (final MapEntry<String, dynamic> data in dataToSave.first.entries) {
          // avoid repeating hard coded keys as primary key, do not add it again
          if (tableKeys.contains(data.key)) {
            continue;
          }

          if (data.value is String) {
            tableKeys.add(data.key);
            schema.write(",${data.key} TEXT DEFAULT ''");
          } else if (data.value is bool) {
            tableKeys.add("_offline_bool_${data.key}");
            schema.write(",_offline_bool_${data.key} INTEGER DEFAULT 0");
          } else if (data.value is double || data.value is int) {
            tableKeys.add(data.key);
            schema.write(",${data.key} REAL DEFAULT 0.0");
          } else if (data.value is List<dynamic> || data.value is Map<dynamic, dynamic> || data.value == null) {
            tableKeys.add("_offline_json_${data.key}");
            schema.write(",_offline_json_${data.key} JSONB DEFAULT 'null'");
          } else {
            logger.e("Unknown type ${data.value.runtimeType} for field ${data.key}", stackTrace: StackTrace.current);
          }
        }

        await dbIsolate.execute("CREATE TABLE $collectionName ($schema)");
        await dbIsolate.execute("CREATE INDEX IF NOT EXISTS _idx_downloaded ON $collectionName (_downloaded)");

        unawaited(
            createAllIndexesForTable(collectionName, indexInstructions, overrideLogger: logger, tableKeys: tableKeys));
      }
    });

    final StringBuffer command = StringBuffer("INSERT OR REPLACE INTO $collectionName(_downloaded");

    final List<String> keys = <String>[];

    for (final String key in dataToSave.first.keys) {
      keys.add(key);
      if (dataToSave.first[key] is bool) {
        command.write(", _offline_bool_$key");
      } else if (dataToSave.first[key] is List<dynamic> ||
          dataToSave.first[key] is Map<dynamic, dynamic> ||
          dataToSave.first[key] == null) {
        command.write(", _offline_json_$key");
      } else {
        command.write(", $key");
      }
    }

    command.write(") VALUES");

    bool first = true;
    final List<dynamic> parameters = <dynamic>[];
    final String now = overrideDownloadTime ?? DateTime.now().toUtc().toString();

    for (final Map<String, dynamic> record in dataToSave) {
      if (!first) {
        command.write(",");
      } else {
        first = false;
      }

      command.write("(?");

      parameters.add(now);

      for (final String key in keys) {
        command.write(", ?");
        if (record[key] == null) {
          if (key.startsWith("_offline_bool_")) {
            parameters.add("false");
          } else {
            parameters.add("null");
          }
        } else if (record[key] is List<dynamic> || record[key] is Map<dynamic, dynamic>) {
          parameters.add(jsonEncode(record[key]));
        } else if (key.startsWith("_offline_json_") && record[key] == null) {
          parameters.add(null);
        } else {
          parameters.add(record[key]);
        }
      }

      command.write(")");
    }

    command.write(";");

    try {
      await dbIsolate.execute(command.toString(), parameters, stackTrace);
    } on SqliteException catch (e) {
      if (!isTest() && e.message.contains("has no column")) {
        logger.i("Dropping table $collectionName: $e");
        await dbIsolate.execute("DROP TABLE $collectionName");
      } else {
        rethrow;
      }
    }
  }
}

String? makePbFilter((String, List<Object?>)? params,
    {List<(String column, bool descending)> sort = const <(String, bool descending)>[],
    Map<String, dynamic>? startAfter}) {
  assert(startAfter == null || (startAfter != null && sort != null),
      "If start after is not null sort must also be not null");

  if (startAfter != null && sort != null) {
    final List<(String name, Object value, bool descending)> sortParams =
        <(String name, Object value, bool descending)>[];

    for (final (String column, bool descending) sortPair in sort) {
      if (startAfter.containsKey(sortPair.$1)) {
        sortParams.add((sortPair.$1, startAfter[sortPair.$1], sortPair.$2));
      }
    }

    if (sortParams.isNotEmpty) {
      final (String, List<Object>) pbCursor = generateCursor(sortParams);
      if (params != null) {
        final List<Object?> objects = List<Object?>.from(params.$2);
        objects.addAll(pbCursor.$2);
        params = ("${params.$1} && (${pbCursor.$1})", objects);
      } else {
        params = pbCursor;
      }
    }
  }

  if (params == null) {
    return null;
  }

  int i = 0;
  final String filter = params.$1.replaceAllMapped(RegExp(r'\?'), (Match match) {
    final dynamic param = params!.$2[i];
    i++;

    if (param is String) {
      return "'${param.replaceAll("'", r"\'")}'";
    } else if (param is DateTime) {
      return "'${param.toUtc()}'";
    } else if (param == null) {
      return "''";
    } else {
      return param.toString();
    }
  });

  assert(i == params.$2.length, "Incorrect number of parameters ($i, ${params.$2.length})");

  return filter;
}

(String, List<Object>) generateCursor(List<(String name, Object value, bool descending)> sortParams,
    {bool pocketBase = true}) {
  if (sortParams.isEmpty) {
    throw ArgumentError('Columns and values must have the same non-zero length');
  }

  final List<String> conditions = <String>[];
  final List<Object> newValues = <Object>[];

  for (int i = 0; i < sortParams.length; i++) {
    String condition = '${sortParams[i].$1} ${sortParams[i].$3 ? "<" : ">"} ?';
    newValues.add(sortParams[i].$2);

    if (i > 0) {
      final String equalsConditions =
          List<String>.generate(i, (int j) => '${sortParams[j].$1} = ?').join(' ${pocketBase ? "&&" : "AND"} ');
      condition = '($condition ${pocketBase ? "&&" : "AND"} $equalsConditions)';
      for (int j = 0; j < i; j++) {
        newValues.add(sortParams[j].$2);
      }
    }

    conditions.add(condition);
  }

  return (conditions.join(' ${pocketBase ? "||" : "OR"} '), newValues);
}

String? makeSortFilter(List<(String column, bool descending)> data) {
  if (data.isEmpty) {
    return null;
  }

  String filter = "";
  for (final (String column, bool descending) sort in data) {
    if (filter != "") {
      filter = "$filter,";
    }
    filter = "$filter${sort.$2 ? "-" : "+"}${sort.$1}";
  }
  return filter;
}
