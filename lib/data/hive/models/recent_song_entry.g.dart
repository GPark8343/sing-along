// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'recent_song_entry.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class RecentSongEntryAdapter extends TypeAdapter<RecentSongEntry> {
  @override
  final typeId = 2;

  @override
  RecentSongEntry read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return RecentSongEntry(
      title: fields[0] as String,
      artist: fields[1] as String,
      cacheKey: fields[2] as String,
      playedAt: fields[3] as DateTime,
    );
  }

  @override
  void write(BinaryWriter writer, RecentSongEntry obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.title)
      ..writeByte(1)
      ..write(obj.artist)
      ..writeByte(2)
      ..write(obj.cacheKey)
      ..writeByte(3)
      ..write(obj.playedAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RecentSongEntryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
