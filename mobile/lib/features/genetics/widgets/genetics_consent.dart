import 'package:flutter/material.dart';

/// What somebody is told before they upload a genome, and the deliberate act
/// of agreeing to it.
///
/// This is the most consequential screen of text in the product, so the
/// wording is here as constants with the reasoning beside them rather than
/// inline in a widget tree where it would get edited by whoever was nearby.
///
/// Four things it has to say, and the fourth is the one almost nobody says:
///
///   * what we keep — a short list, four variants today
///   * what we throw away, and that it includes the disease-risk ones. APOE
///     is named, because somebody worried about Alzheimer's is exactly who
///     needs to know we never read it rather than that we read it and chose
///     silence
///   * that a variant only ever appears beside a blood result they already
///     have, so uploading this on its own produces nothing
///   * that a genome is partly a statement about their relatives, who have
///     not agreed to any of this
///
/// The last one costs us uploads. It is true, a person cannot work it out
/// from the others, and a consent that omits the one fact the person would
/// have wanted is not consent.

const geneticsWhatWeKeep =
    'We read a short list of wellness variants — four at the moment, things '
    'like how your body handles folate, vitamin D and iron. They are the '
    'only genotypes we store.';

const geneticsWhatWeDiscard =
    'Everything else in the file is discarded as it is read and is never '
    'stored, including every variant that carries disease risk. That '
    'includes APOE, the Alzheimer\'s one. We do not read it, so we can never '
    'tell you about it — not now and not if you ask.';

const geneticsHowItIsUsed =
    'A variant is only ever shown beside a blood result you already have. On '
    'its own it says nothing, so if you have had no bloods taken you will see '
    'no difference after uploading this.';

const geneticsAboutRelatives =
    'A genome is partly a statement about your parents, children and '
    'siblings, who have not agreed to any of this. That is worth a thought '
    'before you upload it.';

const geneticsWhatHappensToTheFile =
    'The file itself is deleted once the import has worked. You can remove '
    'the variants and the file at any time, without closing your account.';

const geneticsUnzipFirst =
    'If you downloaded a .zip from 23andMe, unzip it first and pick the .txt '
    'inside.';

/// The sheet shown before the file picker opens.
///
/// Before, not after. A confirmation that appears once the file is chosen is
/// one people click through, because by then they have already decided.
///
/// Returns true if they want to continue.
Future<bool> confirmGeneticsUpload(BuildContext context) async {
  final agreed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (context) => const _ConsentSheet(),
  );
  return agreed ?? false;
}

class _ConsentSheet extends StatelessWidget {
  const _ConsentSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Five paragraphs come to about 1340dp on a 360dp-wide phone, so the
    // facts have to scroll. The BUTTONS do not: they sit outside the scroll
    // view and stay on screen throughout.
    //
    // The alternative — buttons at the end of the scroll, so you must pass
    // every paragraph to reach them — is tempting and wrong. It does not
    // make anybody read, it makes the second upload annoying, and it leaves
    // somebody using a large font size unable to find the button at all.
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Before you upload your genome',
                key: const Key('genetics-consent-title'),
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final (icon, text) in const [
                        (Icons.inventory_2_outlined, geneticsWhatWeKeep),
                        (Icons.delete_outline, geneticsWhatWeDiscard),
                        (Icons.science_outlined, geneticsHowItIsUsed),
                        (Icons.people_outline, geneticsAboutRelatives),
                        (Icons.schedule_outlined, geneticsWhatHappensToTheFile),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(icon,
                                  size: 19, color: theme.colorScheme.outline),
                              const SizedBox(width: 12),
                              Expanded(child: Text(text)),
                            ],
                          ),
                        ),
                      Text(
                        geneticsUnzipFirst,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('genetics-consent-cancel'),
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Not now'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: const Key('genetics-consent-continue'),
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('Choose a file'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Confirming the deletion of everything we hold.
///
/// Asked plainly, and the thing it warns about is that the variants go too —
/// somebody deleting "the file" may not expect to lose what was read out of
/// it, and silently keeping the genotypes after they asked for a deletion
/// would be the wrong way to resolve that ambiguity.
Future<bool> confirmGeneticsDeletion(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('genetics-delete-dialog'),
      title: const Text('Delete your genetic data?'),
      content: const Text(
        'This removes the file you uploaded and the variants we read out of '
        'it. Anything already shown beside a blood result will stop appearing. '
        'Your account and everything else stay as they are.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Keep it'),
        ),
        FilledButton(
          key: const Key('genetics-delete-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
