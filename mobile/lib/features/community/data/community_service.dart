import '../../journal/models/journal_entry.dart';
import '../../journal/models/wellness_data.dart';

class CommunityService {
  const CommunityService();

  List<JournalEntry> posts(WellnessData data, {String? topic}) =>
      data.entries
          .where(
            (entry) =>
                entry.kind == EntryKind.communityPost &&
                (topic == null || entry.fields['topic'] == topic),
          )
          .toList()
        ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));

  List<JournalEntry> replies(WellnessData data, String postId) =>
      data.entries
          .where(
            (entry) =>
                entry.kind == EntryKind.communityReply &&
                entry.parentId == postId,
          )
          .toList()
        ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));

  JournalEntry createPost(String title, String body, String topic) =>
      JournalEntry.create(
        kind: EntryKind.communityPost,
        title: title,
        recordedAt: DateTime.now(),
        notes: body,
        fields: {'topic': topic, 'likes': '0'},
      );

  JournalEntry createReply(String postId, String text) => JournalEntry.create(
    kind: EntryKind.communityReply,
    title: 'Reply',
    recordedAt: DateTime.now(),
    notes: text,
    fields: {'postId': postId},
    parentId: postId,
  );

  JournalEntry toggleLike(JournalEntry post) {
    final liked = post.fields['likedByMe'] == 'true';
    final likes = (post.number('likes').round() + (liked ? -1 : 1)).clamp(
      0,
      999999,
    );
    return JournalEntry(
      id: post.id,
      kind: post.kind,
      title: post.title,
      recordedAt: post.recordedAt,
      notes: post.notes,
      fields: {...post.fields, 'likes': '$likes', 'likedByMe': '${!liked}'},
      parentId: post.parentId,
    );
  }
}
