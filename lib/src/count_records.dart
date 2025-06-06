
import 'package:pocketbase/pocketbase.dart';

import 'get_records.dart';
import 'pocketbase_offline_cache_base.dart';

extension CountWrapper on PbOfflineCache {
	Future<int?> getRecordCount(String collectionName, {
		(String, List<Object?>)? where,
		QuerySource source = QuerySource.any,
	}) async {

		if ((source != QuerySource.server) && !remoteAccessible || source == QuerySource.cache) {

			final Set<String> columnNames = await getColumnNames(dbIsolate, collectionName);
			if (columnNames.isNotEmpty) {
				final List<Map<String, dynamic>> results = await getFromLocalDb(dbIsolate, collectionName, columns: "COUNT(*)", filter: where, columnNames: columnNames);
				return results.first.values.first! as int;
			}

			return 0;
		}

		try {
			return (await pb.collection(collectionName).getList(
				page: 1,
				perPage: 1,
				skipTotal: false,
				filter: makePbFilter(where),
			)).totalItems;
		} on ClientException catch (e) {
			if (!e.isNetworkError()) {
				rethrow;
			}
			if (source == QuerySource.any) {
				return getRecordCount(collectionName, where: where, source: QuerySource.cache);
			} else {
				rethrow;
			}
		}
	}
}
