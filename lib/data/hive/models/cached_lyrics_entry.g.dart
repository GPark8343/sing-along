// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'cached_lyrics_entry.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class CachedLyricsEntryAdapter extends TypeAdapter<CachedLyricsEntry> {
  @override
  final typeId = 0;

  @override
  CachedLyricsEntry read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return CachedLyricsEntry(
      found: fields[0] as bool,
      lines: (fields[1] as List).cast<CachedLyricLine>(),
      cachedAt: fields[2] as DateTime,
    );
  }

  @override
  void write(BinaryWriter writer, CachedLyricsEntry obj) {
    writer
      ..writeByte(3)
      ..writeByte(0)
      ..write(obj.found)
      ..writeByte(1)
      ..write(obj.lines)
      ..writeByte(2)
      ..write(obj.cachedAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CachedLyricsEntryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
