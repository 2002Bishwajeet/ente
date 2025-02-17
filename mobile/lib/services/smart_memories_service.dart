import "dart:math" show min, max;

import "package:flutter/material.dart";
import "package:intl/intl.dart";
import "package:logging/logging.dart";
import "package:ml_linalg/vector.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/db/memories_db.dart";
import "package:photos/db/ml/db.dart";
import "package:photos/events/files_updated_event.dart";
import "package:photos/models/base_location.dart";
import "package:photos/models/file/extensions/file_props.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/local_entity_data.dart";
import "package:photos/models/location/location.dart";
import "package:photos/models/location_tag/location_tag.dart";
import "package:photos/models/memory.dart";
import "package:photos/models/smart_memory.dart";
import "package:photos/models/time_memory.dart";
import "package:photos/models/trip_memory.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/location_service.dart";
import "package:photos/services/machine_learning/ml_computer.dart";
import "package:photos/services/memories_service.dart";
import "package:photos/services/search_service.dart";

class SmartMemoriesService {
  final _logger = Logger("SmartMemoriesService");
  final _memoriesDB = MemoriesDB.instance;

  bool _isInit = false;

  late Locale _locale;
  late Map<int, int> _seenTimes;

  List<SmartMemory>? _cachedMemories;
  Future<List<SmartMemory>>? _future;

  // Singleton pattern
  SmartMemoriesService._privateConstructor();
  static final instance = SmartMemoriesService._privateConstructor();
  factory SmartMemoriesService() => instance;

  void init(BuildContext context) {
    if (_isInit) return;
    _locale = Localizations.localeOf(context);
    _isInit = true;

    Bus.instance.on<FilesUpdatedEvent>().where((event) {
      return event.type == EventType.deletedFromEverywhere;
    }).listen((event) {
      if (_cachedMemories == null) return;
      final generatedIDs = event.updatedFiles
          .where((element) => element.generatedID != null)
          .map((e) => e.generatedID!)
          .toSet();
      for (final memory in _cachedMemories!) {
        memory.memories
            .removeWhere((m) => generatedIDs.contains(m.file.generatedID));
      }
    });
    _logger.info("Smart memories service initialized");
  }

  void clearCache() {
    _cachedMemories = null;
    _future = null;
  }

  Future markMemoryAsSeen(Memory memory) async {
    memory.markSeen();
    await _memoriesDB.markMemoryAsSeen(
      memory,
      DateTime.now().microsecondsSinceEpoch,
    );
    if (_cachedMemories != null && memory.file.generatedID != null) {
      final generatedID = memory.file.generatedID!;
      for (final smartMemory in _cachedMemories!) {
        for (final mem in smartMemory.memories) {
          if (mem.file.generatedID == generatedID) {
            mem.markSeen();
          }
        }
      }
    }
  }

  Future<List<SmartMemory>> getMemories(int? limit) async {
    if (!MemoriesService.instance.showMemories) {
      return [];
    }
    if (_cachedMemories != null) {
      return _cachedMemories!;
    }
    if (_future != null) {
      return _future!;
    }
    _future = _calcMemories();
    return _future!;
  }

  // One general method to get all memories, which calls on internal methods for each separate memory type
  Future<List<SmartMemory>> _calcMemories() async {
    try {
      final List<SmartMemory> memories = [];
      final allFiles = Set<EnteFile>.from(
        await SearchService.instance.getAllFilesForSearch(),
      );
      _seenTimes = await _memoriesDB.getSeenTimes();
      _logger.finest("All files length: ${allFiles.length}");

      // Pause 10 seconds TODO: lau: remove this later
      await Future.delayed(const Duration(seconds: 10));

      // // People memories TODO: lau: add people
      // final peopleMemories = await _getPeopleResults(allFiles, limit);
      // _deductUsedMemories(allFiles, peopleMemories);
      // memories.addAll(peopleMemories);
      // _logger.finest("All files length: ${allFiles.length}");

      // Trip memories
      final tripMemories = await _getTripsResults(allFiles, null);
      _deductUsedMemories(allFiles, tripMemories);
      memories.addAll(tripMemories);
      _logger.finest("All files length: ${allFiles.length}");

      // Time memories
      final timeMemories = await _onThisDayOrWeekResults(allFiles, null);
      _deductUsedMemories(allFiles, timeMemories);
      memories.addAll(timeMemories);
      _logger.finest("All files length: ${allFiles.length}");

      // // Filler memories TODO: lau: add filler results
      // final fillerMemories = await _getFillerResults(limit);
      // _deductUsedMemories(allFiles, fillerMemories);
      // memories.addAll(fillerMemories);
      // _logger.finest("All files length: ${allFiles.length}");

      return memories;
    } catch (e, s) {
      _logger.severe("Error calculating smart memories", e, s);
      return [];
    }
  }

  void _deductUsedMemories(
    Set<EnteFile> files,
    List<SmartMemory> memories,
  ) {
    final usedFiles = <EnteFile>{};
    for (final memory in memories) {
      usedFiles.addAll(memory.memories.map((m) => m.file));
    }
    files.removeAll(usedFiles);
  }

  Future<List<TripMemory>> _getTripsResults(
    Iterable<EnteFile> allFiles,
    int? limit,
  ) async {
    final List<TripMemory> memoryResults = [];
    final Iterable<LocalEntity<LocationTag>> locationTagEntities =
        (await locationService.getLocationTags());
    if (allFiles.isEmpty) return [];
    final currentTime = DateTime.now().toLocal();
    final currentMonth = currentTime.month;
    final cutOffTime = currentTime.subtract(const Duration(days: 365));

    final Map<LocalEntity<LocationTag>, List<EnteFile>> tagToItemsMap = {};
    for (int i = 0; i < locationTagEntities.length; i++) {
      tagToItemsMap[locationTagEntities.elementAt(i)] = [];
    }
    final List<(List<EnteFile>, Location)> smallRadiusClusters = [];
    final List<(List<EnteFile>, Location)> wideRadiusClusters = [];
    // Go through all files and cluster the ones not inside any location tag
    for (EnteFile file in allFiles) {
      if (!file.hasLocation ||
          file.uploadedFileID == null ||
          !file.isOwner ||
          file.creationTime == null) {
        continue;
      }
      // Check if the file is inside any location tag
      bool hasLocationTag = false;
      for (LocalEntity<LocationTag> tag in tagToItemsMap.keys) {
        if (isFileInsideLocationTag(
          tag.item.centerPoint,
          file.location!,
          tag.item.radius,
        )) {
          hasLocationTag = true;
          tagToItemsMap[tag]!.add(file);
        }
      }
      // Cluster the files not inside any location tag (incremental clustering)
      if (!hasLocationTag) {
        // Small radius clustering for base locations
        bool foundSmallCluster = false;
        for (final cluster in smallRadiusClusters) {
          final clusterLocation = cluster.$2;
          if (isFileInsideLocationTag(
            clusterLocation,
            file.location!,
            0.6,
          )) {
            cluster.$1.add(file);
            foundSmallCluster = true;
            break;
          }
        }
        if (!foundSmallCluster) {
          smallRadiusClusters.add(([file], file.location!));
        }
        // Wide radius clustering for trip locations
        bool foundWideCluster = false;
        for (final cluster in wideRadiusClusters) {
          final clusterLocation = cluster.$2;
          if (isFileInsideLocationTag(
            clusterLocation,
            file.location!,
            100.0,
          )) {
            cluster.$1.add(file);
            foundWideCluster = true;
            break;
          }
        }
        if (!foundWideCluster) {
          wideRadiusClusters.add(([file], file.location!));
        }
      }
    }

    // Identify base locations
    final List<BaseLocation> baseLocations = [];
    for (final cluster in smallRadiusClusters) {
      final files = cluster.$1;
      final location = cluster.$2;
      // Check that the photos are distributed over a longer time range (3+ months)
      final creationTimes = <int>[];
      final Set<int> uniqueDays = {};
      for (final file in files) {
        creationTimes.add(file.creationTime!);
        final date = DateTime.fromMicrosecondsSinceEpoch(file.creationTime!);
        final dayStamp =
            DateTime(date.year, date.month, date.day).microsecondsSinceEpoch;
        uniqueDays.add(dayStamp);
      }
      creationTimes.sort();
      if (creationTimes.length < 10) continue;
      final firstCreationTime = DateTime.fromMicrosecondsSinceEpoch(
        creationTimes.first,
      );
      final lastCreationTime = DateTime.fromMicrosecondsSinceEpoch(
        creationTimes.last,
      );
      if (lastCreationTime.difference(firstCreationTime).inDays < 90) {
        continue;
      }
      // Check for a minimum average number of days photos are clicked in range
      final daysRange = lastCreationTime.difference(firstCreationTime).inDays;
      if (uniqueDays.length < daysRange * 0.1) continue;
      // Check if it's a current or old base location
      final bool isCurrent = lastCreationTime.isAfter(
        DateTime.now().subtract(
          const Duration(days: 90),
        ),
      );
      baseLocations.add(BaseLocation(files, location, isCurrent));
    }

    // Identify trip locations
    final List<TripMemory> tripLocations = [];
    clusteredLocations:
    for (final cluster in wideRadiusClusters) {
      final files = cluster.$1;
      final location = cluster.$2;
      // Check that it's at least 10km away from any base or tag location
      bool tooClose = false;
      for (final baseLocation in baseLocations) {
        if (isFileInsideLocationTag(
          baseLocation.location,
          location,
          10.0,
        )) {
          tooClose = true;
          break;
        }
      }
      for (final tag in tagToItemsMap.keys) {
        if (isFileInsideLocationTag(
          tag.item.centerPoint,
          location,
          10.0,
        )) {
          tooClose = true;
          break;
        }
      }
      if (tooClose) continue clusteredLocations;

      // Check that the photos are distributed over a short time range (2-30 days) or multiple short time ranges only
      files.sort((a, b) => a.creationTime!.compareTo(b.creationTime!));
      // Find distinct time blocks (potential trips)
      List<EnteFile> currentBlockFiles = [files.first];
      int blockStart = files.first.creationTime!;
      int lastTime = files.first.creationTime!;
      DateTime lastDateTime = DateTime.fromMicrosecondsSinceEpoch(lastTime);

      for (int i = 1; i < files.length; i++) {
        final currentFile = files[i];
        final currentTime = currentFile.creationTime!;
        final gap = DateTime.fromMicrosecondsSinceEpoch(currentTime)
            .difference(lastDateTime)
            .inDays;

        // If gap is too large, end current block and check if it's a valid trip
        if (gap > 15) {
          // 10 days gap to separate trips. If gap is small, it's likely not a trip
          if (gap < 90) continue clusteredLocations;

          final blockDuration = lastDateTime
              .difference(DateTime.fromMicrosecondsSinceEpoch(blockStart))
              .inDays;

          // Check if current block is a valid trip (2-30 days)
          if (blockDuration >= 2 && blockDuration <= 30) {
            tripLocations.add(
              TripMemory(
                Memory.fromFiles(
                  currentBlockFiles,
                  _seenTimes,
                ), // TODO: lau: properly check last seen times
                location,
                firstCreationTime: blockStart,
                lastCreationTime: lastTime,
              ),
            );
          }

          // Start new block
          currentBlockFiles = [];
          blockStart = currentTime;
        }

        currentBlockFiles.add(currentFile);
        lastTime = currentTime;
        lastDateTime = DateTime.fromMicrosecondsSinceEpoch(lastTime);
      }
      // Check final block
      final lastBlockDuration = lastDateTime
          .difference(DateTime.fromMicrosecondsSinceEpoch(blockStart))
          .inDays;
      if (lastBlockDuration >= 2 && lastBlockDuration <= 30) {
        tripLocations.add(
          TripMemory(
            Memory.fromFiles(currentBlockFiles, _seenTimes),
            location,
            firstCreationTime: blockStart,
            lastCreationTime: lastTime,
          ),
        );
      }
    }

    // Check if any trip locations should be merged
    final List<TripMemory> mergedTrips = [];
    for (final trip in tripLocations) {
      final tripFirstTime = DateTime.fromMicrosecondsSinceEpoch(
        trip.firstCreationTime!,
      );
      final tripLastTime = DateTime.fromMicrosecondsSinceEpoch(
        trip.lastCreationTime!,
      );
      bool merged = false;
      for (int idx = 0; idx < mergedTrips.length; idx++) {
        final otherTrip = mergedTrips[idx];
        final otherTripFirstTime =
            DateTime.fromMicrosecondsSinceEpoch(otherTrip.firstCreationTime!);
        final otherTripLastTime =
            DateTime.fromMicrosecondsSinceEpoch(otherTrip.lastCreationTime!);
        if (tripFirstTime
                .isBefore(otherTripLastTime.add(const Duration(days: 3))) &&
            tripLastTime.isAfter(
              otherTripFirstTime.subtract(const Duration(days: 3)),
            )) {
          mergedTrips[idx] = TripMemory(
            otherTrip.memories + trip.memories,
            otherTrip.location,
            firstCreationTime:
                min(otherTrip.firstCreationTime!, trip.firstCreationTime!),
            lastCreationTime:
                max(otherTrip.lastCreationTime!, trip.lastCreationTime!),
          );
          _logger.finest('Merged two trip locations');
          merged = true;
          break;
        }
      }
      if (merged) continue;
      mergedTrips.add(
        TripMemory(
          trip.memories,
          trip.location,
          firstCreationTime: trip.firstCreationTime,
          lastCreationTime: trip.lastCreationTime,
        ),
      );
    }

    // Remove too small and too recent trips
    final List<TripMemory> validTrips = [];
    for (final trip in mergedTrips) {
      if (trip.memories.length >= 20 &&
          trip.averageCreationTime() < cutOffTime.microsecondsSinceEpoch) {
        validTrips.add(trip);
      }
    }

    // For now for testing let's just surface all base locations
    for (final baseLocation in baseLocations) {
      String name = "Base (${baseLocation.isCurrentBase ? 'current' : 'old'})";
      final String? locationName = await _tryFindLocationName(
        Memory.fromFiles(baseLocation.files, _seenTimes),
        base: true,
      );
      if (locationName != null) {
        name =
            "$locationName (Base, ${baseLocation.isCurrentBase ? 'current' : 'old'})";
      }
      memoryResults.add(
        TripMemory(
          Memory.fromFiles(baseLocation.files, _seenTimes),
          baseLocation.location,
          name: name,
        ),
      );
    }

    // For now we surface the two most recent trips of current month, and if none, the earliest upcoming redundant trip
    // Group the trips per month and then year
    final Map<int, Map<int, List<TripMemory>>> tripsByMonthYear = {};
    for (final trip in validTrips) {
      final tripDate =
          DateTime.fromMicrosecondsSinceEpoch(trip.averageCreationTime());
      tripsByMonthYear
          .putIfAbsent(tripDate.month, () => {})
          .putIfAbsent(tripDate.year, () => [])
          .add(trip);
    }

    // Flatten trips for the current month and annotate with their average date.
    final List<TripMemory> currentMonthTrips = [];
    if (tripsByMonthYear.containsKey(currentMonth)) {
      for (final trips in tripsByMonthYear[currentMonth]!.values) {
        for (final trip in trips) {
          currentMonthTrips.add(trip);
        }
      }
    }

    // If there are past trips this month, show the one or two most recent ones.
    if (currentMonthTrips.isNotEmpty) {
      currentMonthTrips.sort(
        (a, b) => b.averageCreationTime().compareTo(a.averageCreationTime()),
      );
      final tripsToShow = currentMonthTrips.take(2);
      for (final trip in tripsToShow) {
        final year =
            DateTime.fromMicrosecondsSinceEpoch(trip.averageCreationTime())
                .year;
        final String? locationName = await _tryFindLocationName(trip.memories);
        String name =
            "Trip in $year"; // TODO lau: extract strings for translation
        if (locationName != null) {
          name = "Trip to $locationName";
        } else if (year == currentTime.year - 1) {
          name = "Last year's trip";
        }
        final photoSelection = await _bestSelection(trip.memories);
        memoryResults.add(
          trip.copyWith(
            memories: photoSelection,
            name: name,
          ),
        );
        if (limit != null && memoryResults.length >= limit) {
          return memoryResults;
        }
      }
    }
    // Otherwise, if no trips happened in the current month,
    // look for the earliest upcoming trip in another month that has 3+ trips.
    else {
      // TODO lau: make sure the same upcoming trip isn't shown multiple times over multiple months
      final sortedUpcomingMonths =
          List<int>.generate(12, (i) => ((currentMonth + i) % 12) + 1);
      checkUpcomingMonths:
      for (final month in sortedUpcomingMonths) {
        if (tripsByMonthYear.containsKey(month)) {
          final List<TripMemory> thatMonthTrips = [];
          for (final trips in tripsByMonthYear[month]!.values) {
            for (final trip in trips) {
              thatMonthTrips.add(trip);
            }
          }
          if (thatMonthTrips.length >= 3) {
            // take and use the third earliest trip
            thatMonthTrips.sort(
              (a, b) =>
                  a.averageCreationTime().compareTo(b.averageCreationTime()),
            );
            final trip = thatMonthTrips[2];
            final year =
                DateTime.fromMicrosecondsSinceEpoch(trip.averageCreationTime())
                    .year;
            final String? locationName =
                await _tryFindLocationName(trip.memories);
            String name = "Trip in $year";
            if (locationName != null) {
              name = "Trip to $locationName";
            } else if (year == currentTime.year - 1) {
              name = "Last year's trip";
            }
            final photoSelection = await _bestSelection(trip.memories);
            memoryResults.add(
              trip.copyWith(
                memories: photoSelection,
                name: name,
              ),
            );
            break checkUpcomingMonths;
          }
        }
      }
    }
    return memoryResults;
  }

  Future<List<TimeMemory>> _onThisDayOrWeekResults(
    Iterable<EnteFile> allFiles,
    int? limit,
  ) async {
    final List<TimeMemory> memoryResult = [];
    if (allFiles.isEmpty) return [];

    final currentTime = DateTime.now().toLocal();
    final currentDayMonth = currentTime.month * 100 + currentTime.day;
    final currentWeek = _getWeekNumber(currentTime);
    final currentMonth = currentTime.month;
    final cutOffTime = currentTime.subtract(const Duration(days: 365));
    final averageDailyPhotos = allFiles.length / 365;
    final significantDayThreshold = averageDailyPhotos * 0.25;
    final significantWeekThreshold = averageDailyPhotos * 0.40;

    // Group files by day-month and year
    final dayMonthYearGroups = <int, Map<int, List<Memory>>>{};

    for (final file in allFiles) {
      if (file.creationTime! > cutOffTime.microsecondsSinceEpoch) continue;

      final creationTime =
          DateTime.fromMicrosecondsSinceEpoch(file.creationTime!);
      final dayMonth = creationTime.month * 100 + creationTime.day;
      final year = creationTime.year;

      dayMonthYearGroups
          .putIfAbsent(dayMonth, () => {})
          .putIfAbsent(year, () => [])
          .add(Memory.fromFile(file, _seenTimes));
    }

    // Process each nearby day-month to find significant days
    for (final dayMonth in dayMonthYearGroups.keys) {
      final dayDiff = dayMonth - currentDayMonth;
      if (dayDiff < 0 || dayDiff > 2) continue;
      // TODO: lau: this doesn't cover month changes properly

      final yearGroups = dayMonthYearGroups[dayMonth]!;
      final significantDays = yearGroups.entries
          .where((e) => e.value.length > significantDayThreshold)
          .map((e) => e.key)
          .toList();

      if (significantDays.length >= 3) {
        // THE ISSUE IS HERE, MOST LIKELY IN THE SELECTION!
        // Combine all years for this day-month
        final date =
            DateTime(currentTime.year, dayMonth ~/ 100, dayMonth % 100);
        final allPhotos = yearGroups.values.expand((x) => x).toList();
        final photoSelection = await _bestSelection(allPhotos);

        memoryResult.add(
          TimeMemory(
            photoSelection,
            name: "${DateFormat('MMMM d').format(date)} through the years",
          ),
        );
      } else {
        // Individual entries for significant years
        for (final year in significantDays) {
          final date = DateTime(year, dayMonth ~/ 100, dayMonth % 100);
          final files = yearGroups[year]!;
          final photoSelection = await _bestSelection(files);
          String name = DateFormat.yMMMd(_locale.languageCode).format(date);
          if (date.day == currentTime.day && date.month == currentTime.month) {
            name = "This day, ${currentTime.year - date.year} years back";
          }

          memoryResult.add(
            TimeMemory(
              photoSelection,
              name: name,
            ),
          );
        }
      }

      if (limit != null && memoryResult.length >= limit) return memoryResult;
    }

    // process to find significant weeks (only if there are no significant days)
    if (memoryResult.isEmpty) {
      // Group files by week and year
      final currentWeekYearGroups = <int, List<Memory>>{};
      for (final file in allFiles) {
        if (file.creationTime! > cutOffTime.microsecondsSinceEpoch) continue;

        final creationTime =
            DateTime.fromMicrosecondsSinceEpoch(file.creationTime!);
        final week = _getWeekNumber(creationTime);
        if (week != currentWeek) continue;
        final year = creationTime.year;

        currentWeekYearGroups
            .putIfAbsent(year, () => [])
            .add(Memory.fromFile(file, _seenTimes));
      }

      // Process the week and see if it's significant
      if (currentWeekYearGroups.isNotEmpty) {
        final significantWeeks = currentWeekYearGroups.entries
            .where((e) => e.value.length > significantWeekThreshold)
            .map((e) => e.key)
            .toList();
        if (significantWeeks.length >= 3) {
          // Combine all years for this week
          final allPhotos =
              currentWeekYearGroups.values.expand((x) => x).toList();
          final photoSelection = await _bestSelection(allPhotos);
          const name = "This week through the years";
          memoryResult.add(
            TimeMemory(
              photoSelection,
              name: name,
            ),
          );
        } else {
          // Individual entries for significant years
          for (final year in significantWeeks) {
            final date = DateTime(year, 1, 1).add(
              Duration(days: (currentWeek - 1) * 7),
            );
            final files = currentWeekYearGroups[year]!;
            final photoSelection = await _bestSelection(files);
            final name =
                "This week, ${currentTime.year - date.year} years back";

            memoryResult.add(
              TimeMemory(
                photoSelection,
                name: name,
              ),
            );
          }
        }
      }
    }

    if (limit != null && memoryResult.length >= limit) return memoryResult;

    // process to find fillers (months)
    const wantedMemories = 3;
    final neededMemories = wantedMemories - memoryResult.length;
    if (neededMemories <= 0) return memoryResult;
    const monthSelectionSize = 20;

    // Group files by month and year
    final currentMonthYearGroups = <int, List<Memory>>{};
    for (final file in allFiles) {
      if (file.creationTime! > cutOffTime.microsecondsSinceEpoch) continue;

      final creationTime =
          DateTime.fromMicrosecondsSinceEpoch(file.creationTime!);
      final month = creationTime.month;
      if (month != currentMonth) continue;
      final year = creationTime.year;

      currentMonthYearGroups
          .putIfAbsent(year, () => [])
          .add(Memory.fromFile(file, _seenTimes));
    }

    // Add the largest two months plus the month through the years
    final sortedYearsForCurrentMonth = currentMonthYearGroups.keys.toList()
      ..sort(
        (a, b) => currentMonthYearGroups[b]!.length.compareTo(
              currentMonthYearGroups[a]!.length,
            ),
      );
    if (neededMemories > 1) {
      for (int i = neededMemories; i > 1; i--) {
        if (sortedYearsForCurrentMonth.isEmpty) break;
        final year = sortedYearsForCurrentMonth.removeAt(0);
        final monthYearFiles = currentMonthYearGroups[year]!;
        final photoSelection = await _bestSelection(
          monthYearFiles,
          prefferedSize: monthSelectionSize,
        );
        final monthName = DateFormat.MMMM(_locale.languageCode)
            .format(DateTime(year, currentMonth));
        final name = monthName + ", ${currentTime.year - year} years back";
        memoryResult.add(
          TimeMemory(
            photoSelection,
            name: name,
          ),
        );
      }
    }
    // Show the month through the remaining years
    if (sortedYearsForCurrentMonth.isEmpty) return memoryResult;
    final allPhotos = sortedYearsForCurrentMonth
        .expand((year) => currentMonthYearGroups[year]!)
        .toList();
    final photoSelection =
        await _bestSelection(allPhotos, prefferedSize: monthSelectionSize);
    final monthName = DateFormat.MMMM(_locale.languageCode)
        .format(DateTime(currentTime.year, currentMonth));
    final name = monthName + " through the years";
    memoryResult.add(
      TimeMemory(
        photoSelection,
        name: name,
      ),
    );

    return memoryResult;
  }

  int _getWeekNumber(DateTime date) {
    // Get day of year (1-366)
    final int dayOfYear = int.parse(DateFormat('D').format(date));
    // Integer division by 7 and add 1 to start from week 1
    return ((dayOfYear - 1) ~/ 7) + 1;
  }

  Future<String?> _tryFindLocationName(
    List<Memory> memories, {
    bool base = false,
  }) async {
    final files = Memory.filesFromMemories(memories);
    final results = await locationService.getFilesInCity(files, '');
    final List<City> sortedByResultCount = results.keys.toList()
      ..sort((a, b) => results[b]!.length.compareTo(results[a]!.length));
    if (sortedByResultCount.isEmpty) return null;
    final biggestPlace = sortedByResultCount.first;
    if (results[biggestPlace]!.length > files.length / 2) {
      return biggestPlace.city;
    }
    if (results.length > 2 &&
        results.keys.map((city) => city.country).toSet().length == 1 &&
        !base) {
      return biggestPlace.country;
    }
    return null;
  }

  /// Returns the best selection of files from the given list.
  /// Makes sure that the selection is not more than [prefferedSize] or 10 files,
  /// and that each year of the original list is represented.
  Future<List<Memory>> _bestSelection(
    List<Memory> memories, {
    int? prefferedSize,
  }) async {
    // final files = Memory.filesFromMemories(memories);
    final fileCount = memories.length;
    int targetSize = prefferedSize ?? 10;
    if (fileCount <= targetSize) return memories;
    final safeMemories =
        memories.where((memory) => memory.file.uploadedFileID != null).toList();
    final safeCount = safeMemories.length;
    final fileIDs = safeMemories.map((e) => e.file.uploadedFileID!).toSet();
    final fileIdToFace = await MLDataDB.instance.getFacesForFileIDs(fileIDs);
    final faceIDs =
        fileIdToFace.values.expand((x) => x.map((face) => face.faceID)).toSet();
    final faceIDsToPersonID =
        await MLDataDB.instance.getFaceIdToPersonIdForFaces(faceIDs);
    final fileIdToClip =
        await MLDataDB.instance.getClipVectorsForFileIDs(fileIDs);
    final allYears = safeMemories.map((e) {
      final creationTime =
          DateTime.fromMicrosecondsSinceEpoch(e.file.creationTime!);
      return creationTime.year;
    }).toSet();

    // Get clip scores for each file
    const query =
        'Photo of a precious memory radiating warmth, vibrant energy, or quiet beauty — alive with color, light, or emotion';
    // TODO: lau: optimize this later so we don't keep computing embedding
    final textEmbedding = await MLComputer.instance.runClipText(query);
    final textVector = Vector.fromList(textEmbedding);
    const clipThreshold = 0.75;
    final fileToScore = <int, double>{};
    for (final mem in safeMemories) {
      final clip = fileIdToClip[mem.file.uploadedFileID!];
      if (clip == null) {
        fileToScore[mem.file.uploadedFileID!] = 0;
        continue;
      }
      final score = clip.vector.dot(textVector);
      fileToScore[mem.file.uploadedFileID!] = score;
    }

    // Get face scores for each file
    final fileToFaceCount = <int, int>{};
    for (final mem in safeMemories) {
      final fileID = mem.file.uploadedFileID!;
      fileToFaceCount[fileID] = 0;
      final faces = fileIdToFace[fileID];
      if (faces == null || faces.isEmpty) {
        continue;
      }
      for (final face in faces) {
        if (faceIDsToPersonID.containsKey(face.faceID)) {
          fileToFaceCount[fileID] = fileToFaceCount[fileID]! + 10;
        } else {
          fileToFaceCount[fileID] = fileToFaceCount[fileID]! + 1;
        }
      }
    }

    final filteredMemories = <Memory>[];
    if (allYears.length <= 1) {
      // TODO: lau: eventually this sorting might have to be replaced with some scoring system
      // sort first on clip embeddings score (descending)
      safeMemories.sort(
        (a, b) => fileToScore[b.file.uploadedFileID!]!
            .compareTo(fileToScore[a.file.uploadedFileID!]!),
      );
      // then sort on faces (descending), heavily prioritizing named faces
      safeMemories.sort(
        (a, b) => fileToFaceCount[b.file.uploadedFileID!]!
            .compareTo(fileToFaceCount[a.file.uploadedFileID!]!),
      );

      // then filter out similar images as much as possible
      filteredMemories.add(safeMemories.first);
      int skipped = 0;
      filesLoop:
      for (final mem in safeMemories.sublist(1)) {
        if (filteredMemories.length >= targetSize) break;
        final clip = fileIdToClip[mem.file.uploadedFileID!];
        if (clip != null && (safeCount - skipped) > targetSize) {
          for (final filteredMem in filteredMemories) {
            final fClip = fileIdToClip[filteredMem.file.uploadedFileID!];
            if (fClip == null) continue;
            final similarity = clip.vector.dot(fClip.vector);
            if (similarity > clipThreshold) {
              skipped++;
              continue filesLoop;
            }
          }
        }
        filteredMemories.add(mem);
      }
    } else {
      // Multiple years, each represented and roughly equally distributed
      if (prefferedSize == null && (allYears.length * 2) > 10) {
        targetSize = allYears.length * 3;
        if (safeCount < targetSize) return safeMemories;
      }

      // Group files by year and sort each year's list by CLIP then face count
      final yearToFiles = <int, List<Memory>>{};
      for (final safeMem in safeMemories) {
        final creationTime =
            DateTime.fromMicrosecondsSinceEpoch(safeMem.file.creationTime!);
        final year = creationTime.year;
        yearToFiles.putIfAbsent(year, () => []).add(safeMem);
      }

      for (final year in yearToFiles.keys) {
        final yearFiles = yearToFiles[year]!;
        // sort first on clip embeddings score (descending)
        yearFiles.sort(
          (a, b) => fileToScore[b.file.uploadedFileID!]!
              .compareTo(fileToScore[a.file.uploadedFileID!]!),
        );
        // then sort on faces (descending), heavily prioritizing named faces
        yearFiles.sort(
          (a, b) => fileToFaceCount[b.file.uploadedFileID!]!
              .compareTo(fileToFaceCount[a.file.uploadedFileID!]!),
        );
      }

      // Then join the years together one by one and filter similar images
      final years = yearToFiles.keys.toList()
        ..sort((a, b) => b.compareTo(a)); // Recent years first
      int round = 0;
      int skipped = 0;
      whileLoop:
      while (filteredMemories.length + skipped < safeCount) {
        yearLoop:
        for (final year in years) {
          final yearFiles = yearToFiles[year]!;
          if (yearFiles.isEmpty) continue;
          final newMem = yearFiles.removeAt(0);
          if (round != 0 && (safeCount - skipped) > targetSize) {
            // check for filtering
            final clip = fileIdToClip[newMem.file.uploadedFileID!];
            if (clip != null) {
              for (final filteredMem in filteredMemories) {
                final fClip = fileIdToClip[filteredMem.file.uploadedFileID!];
                if (fClip == null) continue;
                final similarity = clip.vector.dot(fClip.vector);
                if (similarity > clipThreshold) {
                  skipped++;
                  continue yearLoop;
                }
              }
            }
          }
          filteredMemories.add(newMem);
          if (filteredMemories.length >= targetSize ||
              filteredMemories.length + skipped >= safeCount) {
            break whileLoop;
          }
        }
        round++;
        // Extra safety to prevent infinite loops
        if (round > safeCount) break;
      }
    }

    // Order the final selection chronologically
    filteredMemories
        .sort((a, b) => b.file.creationTime!.compareTo(a.file.creationTime!));
    return filteredMemories;
  }
}
