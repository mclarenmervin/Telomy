import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/widgets/async_action.dart';
import '../../journal/models/journal_entry.dart';
import '../../journal/providers/wellness_provider.dart';
import '../../journal/screens/entry_editor.dart';
import '../data/community_service.dart';

class CommunityScreen extends ConsumerStatefulWidget {
  const CommunityScreen({super.key});
  @override
  ConsumerState<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends ConsumerState<CommunityScreen> {
  static const topics = [
    'General',
    'Sleep',
    'Fitness',
    'Nutrition',
    'Recovery',
  ];
  String? topic;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(wellnessProvider);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Community', style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 8),
        const Text('Share experiences and support healthy routines together.'),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: () => openEntryEditor(context, EntryKind.communityPost),
          icon: const Icon(Icons.edit_outlined),
          label: const Text('Create post'),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('All'),
              selected: topic == null,
              onSelected: (_) => setState(() => topic = null),
            ),
            for (final item in topics)
              ChoiceChip(
                label: Text(item),
                selected: topic == item,
                onSelected: (_) => setState(() => topic = item),
              ),
          ],
        ),
        const SizedBox(height: 18),
        ...state.when(
          loading: () => [const LinearProgressIndicator()],
          error: (_, _) => [const Text('Unable to load the community feed.')],
          data: (data) {
            final service = const CommunityService();
            final posts = service.posts(data, topic: topic);
            return [
              if (posts.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(22),
                    child: Text('No posts in this topic yet.'),
                  ),
                ),
              for (final post in posts)
                _PostCard(
                  post: post,
                  replies: service.replies(data, post.id),
                  onLike: () => runAction(
                    context,
                    () => ref
                        .read(wellnessProvider.notifier)
                        .saveEntry(service.toggleLike(post)),
                  ),
                  onReply: () => _reply(post),
                  onDelete: () => runAction(
                    context,
                    () => ref
                        .read(wellnessProvider.notifier)
                        .deleteEntry(post.id),
                    success: 'Post deleted',
                  ),
                ),
              const SizedBox(height: 12),
              const Text(
                'Community posts are personal experiences, not medical advice. Do not share private identifying or emergency information.',
                style: TextStyle(fontSize: 12),
              ),
            ];
          },
        ),
      ],
    );
  }

  Future<void> _reply(JournalEntry post) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reply'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          maxLength: 1000,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Reply'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value?.isNotEmpty == true && mounted) {
      await runAction(
        context,
        () => ref
            .read(wellnessProvider.notifier)
            .saveEntry(const CommunityService().createReply(post.id, value!)),
      );
    }
  }
}

class _PostCard extends StatelessWidget {
  const _PostCard({
    required this.post,
    required this.replies,
    required this.onLike,
    required this.onReply,
    required this.onDelete,
  });
  final JournalEntry post;
  final List<JournalEntry> replies;
  final VoidCallback onLike, onReply, onDelete;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Chip(label: Text(post.fields['topic'] ?? 'General')),
              const Spacer(),
              Text(DateFormat.MMMd().format(post.recordedAt)),
              IconButton(
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          Text(post.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(post.notes),
          const SizedBox(height: 12),
          Row(
            children: [
              TextButton.icon(
                onPressed: onLike,
                icon: Icon(
                  post.fields['likedByMe'] == 'true'
                      ? Icons.favorite
                      : Icons.favorite_border,
                ),
                label: Text('${post.number('likes').round()}'),
              ),
              TextButton.icon(
                onPressed: onReply,
                icon: const Icon(Icons.chat_bubble_outline),
                label: Text('${replies.length}'),
              ),
            ],
          ),
          for (final reply in replies)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 16),
              child: Text('↳ ${reply.notes}'),
            ),
        ],
      ),
    ),
  );
}
