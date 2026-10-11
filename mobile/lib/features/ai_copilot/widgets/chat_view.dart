import 'package:flutter/material.dart';

import '../data/chat_repository.dart';
import '../models/chat_turn.dart';

/// The conversation.
///
/// The screen renders what the server said and never composes an answer of its
/// own. The one thing it writes for itself is the question, shown the instant
/// it is sent — waiting for the round trip to display your own words makes the
/// product feel broken — and an explanation when nothing came back.
///
/// Dependencies arrive as arguments rather than through providers so this is
/// testable as a widget, which is where the behaviour worth checking lives:
/// what the user sees while they wait, and whether a refusal can be mistaken
/// for an answer.
class ChatView extends StatefulWidget {
  const ChatView({
    super.key,
    required this.history,
    required this.onAsk,
    this.footer,
  });

  /// Oldest first, which is the order it is read in.
  final List<ChatTurn> history;

  final Future<ChatTurn> Function(String message) onAsk;

  /// Anything the screen wants under the conversation — the locally computed
  /// patterns, on the real screen.
  final Widget? footer;

  @override
  State<ChatView> createState() => _ChatViewState();
}

/// Openers, phrased as the questions they actually send. Each one is answerable
/// from a tool the concierge has: the stored readiness score, confirmed lab
/// values, and findings a clinician signed. A suggestion the tools cannot
/// answer teaches the user that the feature does not work.
const _suggestions = [
  'Why was my readiness low this week?',
  'What did my last lab report show?',
  'Has a clinician signed off anything for me?',
];

class _ChatViewState extends State<ChatView> {
  final _input = TextEditingController();
  // Whether the composer has focus is the one reliable signal that a keyboard
  // is up. `MediaQuery.of(context).viewInsets` is stripped by the Scaffold
  // that resizes for the keyboard, and reading the view directly came back
  // zero on a device even with the keyboard plainly open.
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _sent = <ChatTurn>[];
  ChatTurn? _pending;
  String? _failure;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<ChatTurn> get _conversation => [
        ...widget.history,
        ..._sent,
        ?_pending,
      ];

  bool get _busy => _pending != null;

  Future<void> _ask(String raw) async {
    final message = raw.trim();
    // A blank message is not a question, and it would cost a model call to
    // find that out on the server.
    if (message.isEmpty || _busy) return;

    setState(() {
      _pending = ChatTurn.pending(message);
      _failure = null;
      _input.clear();
    });
    _scrollToEnd();

    try {
      final turn = await widget.onAsk(message);
      if (!mounted) return;
      setState(() {
        _sent.add(turn);
        _pending = null;
      });
    } on ChatUnavailable catch (error) {
      if (!mounted) return;
      setState(() {
        _pending = null;
        _failure = error.message;
        // The question goes back in the box. Retyping something the product
        // failed to answer is the kind of small insult that stops people
        // using a feature.
        _input.text = message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _pending = null;
        _failure = 'That question could not be answered just now.';
        _input.text = message;
      });
    }
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final conversation = _conversation;
    return Column(
      children: [
        Expanded(
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            children: [
              _Preamble(empty: conversation.isEmpty),
              if (conversation.isEmpty)
                _Suggestions(onTap: _busy ? null : _ask)
              else
                for (final turn in conversation) _TurnTile(turn: turn),
              if (_failure != null) _Failure(message: _failure!),
              if (widget.footer != null) widget.footer!,
            ],
          ),
        ),
        _Composer(
          controller: _input,
          focusNode: _focus,
          focused: _focus.hasFocus,
          busy: _busy,
          onSend: () => _ask(_input.text),
        ),
      ],
    );
  }
}

class _Preamble extends StatelessWidget {
  const _Preamble({required this.empty});

  final bool empty;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Sinc', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        // Said on the screen and not only in the answers. A conversational
        // interface invites medical questions, and the standing limit should
        // not depend on the model remembering to mention it.
        const Text(
          'Ask about anything in your own records. I can describe what has '
          'been measured and repeat what a clinician has signed off — I am '
          'not a clinician and cannot diagnose or advise on treatment.',
        ),
        SizedBox(height: empty ? 20 : 24),
      ],
    );
  }
}

class _Suggestions extends StatelessWidget {
  const _Suggestions({required this.onTap});

  final void Function(String)? onTap;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      key: const Key('chat-suggestions'),
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final suggestion in _suggestions)
          ActionChip(
            label: Text(suggestion),
            onPressed: onTap == null ? null : () => onTap!(suggestion),
          ),
      ],
    );
  }
}

class _TurnTile extends StatelessWidget {
  const _TurnTile({required this.turn});

  final ChatTurn turn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 320),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Text(turn.asked),
            ),
          ),
          const SizedBox(height: 12),
          if (turn.isAwaitingAnswer)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (turn.isEmergency)
            _Emergency(text: turn.answered)
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(turn.answered),
                if (turn.quotesSignedFinding) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.verified_outlined, size: 15),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Includes a finding a clinician signed. You can read '
                          'it in full under Lab results.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

/// The deterministic safety response, which fired before any model ran.
///
/// Given its own treatment because it is the one answer on this screen that
/// somebody may need to act on in the next few minutes, and no follow-up is
/// offered under it.
class _Emergency extends StatelessWidget {
  const _Emergency({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('chat-emergency'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: SelectableText(
              text,
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _Failure extends StatelessWidget {
  const _Failure({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_outlined, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.focused,
    required this.busy,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// A focused composer means a keyboard, which moves the shell's floating
  /// button up into this row.
  final bool focused;
  final bool busy;
  final VoidCallback onSend;

  /// How far the shell's floating action button reaches into this row.
  ///
  /// `AppShell` docks a 56px FAB into the notch of its bottom bar, so it
  /// stands ~28px proud of the bar and lands on the bottom centre of the
  /// composer. When a keyboard is open the bar goes with it and the same
  /// button floats just above the keyboard, which is further into the
  /// composer — on a device it sat across the text field and covered what was
  /// being typed. On a wide layout it floats at the bottom right instead,
  /// which is where the send button is.
  ///
  /// The keyboard is detected by the composer having focus. Two other ways
  /// were tried on a device and both read zero with the keyboard plainly
  /// open: `MediaQuery.of(context).viewInsets`, which the resizing Scaffold
  /// strips out of what it hands its body, and the view's own insets.
  ///
  /// All three are the host's geometry rather than this widget's, and the
  /// composer simply keeps out of the way. Found on the emulator: every widget
  /// test passed with the two overlapping, because nothing in a test renders
  /// the shell around this screen.
  static const _fabSize = 56.0;
  static const _dockedClearance = 36.0;
  static const _floatingClearance = 72.0;
  static const _wideBreakpoint = 760.0;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          4,
          wide ? _dockedClearance + _fabSize : 16,
          wide
              ? 12
              : focused
                  ? _floatingClearance
                  : _dockedClearance,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                key: const Key('chat-input'),
                controller: controller,
                focusNode: focusNode,
                minLines: 1,
                maxLines: 4,
                // Matches the server's limit and the column's check
                // constraint, so a long question is stopped by the keyboard
                // rather than by a refusal after the fact.
                maxLength: 2000,
                textInputAction: TextInputAction.send,
                onSubmitted: busy ? null : (_) => onSend(),
                decoration: const InputDecoration(
                  hintText: 'Ask about your records',
                  counterText: '',
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              key: const Key('chat-send'),
              // Disabled while a turn is in flight: every turn costs a model
              // call and counts against the daily cap, so a double tap must
              // not spend two of them.
              onPressed: busy ? null : onSend,
              icon: const Icon(Icons.arrow_upward),
            ),
          ],
        ),
      ),
    );
  }
}
