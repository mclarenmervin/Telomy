/// The fourteen pieces the prototype's 73 screens are built from, and
/// nothing else.
///
/// Importing this one file is the intended way to use them. The split into
/// four files underneath is for reading, not for picking and choosing.
///
/// From F9 onward, a number rendered without [Prov] is a review failure. That
/// rule is cheap to hold only because the component exists first, which is
/// the order the prototype got right and the opposite of how a feature
/// usually arrives.
library;

export '../../app/theme/app_status.dart' show AppStatus, StatusTone;
export 'prov.dart' show ConfBar, ConfSegment, Confidence, Prov;
export 'states.dart' show Empty, EmptyAction, EmptyTone, ErrorState, Loading, showToast;
export 'surfaces.dart'
    show AppCard, AppRow, AppScreen, CardTone, ListRow, Section, SectionAction,
        Segmented, Stat;
export 'text.dart' show AppChip, StatusChip, T, TextVariant;
