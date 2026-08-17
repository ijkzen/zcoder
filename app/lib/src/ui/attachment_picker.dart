import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// A file the user picked in the attachment sheet, not yet uploaded.
///
/// On the conversation page it is uploaded immediately; on the sessions page
/// (no session exists yet) it is staged locally and handed to the new session
/// as a pending upload.
class PickedAttachment {
  final String name;
  final String mime;
  final Uint8List bytes;

  const PickedAttachment({
    required this.name,
    required this.mime,
    required this.bytes,
  });
}

String mimeForFileName(String name) {
  final ext = name.split('.').last.toLowerCase();
  switch (ext) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'pdf':
      return 'application/pdf';
    case 'txt':
      return 'text/plain';
    case 'md':
      return 'text/markdown';
    case 'json':
      return 'application/json';
    case 'zip':
      return 'application/zip';
    default:
      return 'application/octet-stream';
  }
}

/// Bottom sheet offering gallery-image / any-file picking. Returns null when
/// the sheet or the picker is dismissed; picker/plugin errors propagate to
/// the caller (it owns the SnackBar).
Future<PickedAttachment?> showAttachmentPicker(BuildContext context) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('从相册选择图片'),
            onTap: () => Navigator.pop(sheetContext, 'image'),
          ),
          ListTile(
            leading: const Icon(Icons.insert_drive_file_outlined),
            title: const Text('选择文件'),
            onTap: () => Navigator.pop(sheetContext, 'file'),
          ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return null;
  if (choice == 'image') {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 2048,
    );
    if (picked == null) return null;
    return PickedAttachment(
      name: picked.name,
      mime: mimeForFileName(picked.name),
      bytes: await picked.readAsBytes(),
    );
  }
  final files = await FilePicker.pickFiles();
  final file = files.isEmpty ? null : files.first;
  if (file == null) return null;
  return PickedAttachment(
    name: file.name,
    mime: mimeForFileName(file.name),
    bytes: await file.readAsBytes(),
  );
}
