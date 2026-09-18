// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'cached_lyric_line.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class CachedLyricLineAdapter extends TypeAdapter<CachedLyricLine> {
  @override
  final typeId = 1;

  @override
  CachedLyricLine read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return CachedLyricLine(
      timestampMs: (fields[0] as num?)?.toInt(),
      original: fields[1] as String,
      phonetic: fields[2] as String?,
      translation: fields[3] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, CachedLyricLine obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.timestampMs)
      ..writeByte(1)
      ..write(obj.original)
      ..writeByte(2)
      ..write(obj.phonetic)
      ..writeByte(3)
      ..write(obj.translation);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CachedLyricLineAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
