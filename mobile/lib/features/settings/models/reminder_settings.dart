class ReminderSettings {
  const ReminderSettings({
    this.enabled = false,
    this.water = true,
    this.movement = true,
    this.sleep = true,
    this.dailyReview = true,
    this.trendAlerts = true,
    this.waterMinute = 14 * 60,
    this.movementMinute = 16 * 60,
    this.sleepMinute = 22 * 60,
    this.reviewMinute = 20 * 60,
    this.restingHeartRateChange = 15,
    this.minimumSleepHours = 6,
  });

  final bool enabled;
  final bool water;
  final bool movement;
  final bool sleep;
  final bool dailyReview;
  final bool trendAlerts;
  final int waterMinute;
  final int movementMinute;
  final int sleepMinute;
  final int reviewMinute;
  final double restingHeartRateChange;
  final double minimumSleepHours;

  ReminderSettings copyWith({
    bool? enabled,
    bool? water,
    bool? movement,
    bool? sleep,
    bool? dailyReview,
    bool? trendAlerts,
    int? waterMinute,
    int? movementMinute,
    int? sleepMinute,
    int? reviewMinute,
    double? restingHeartRateChange,
    double? minimumSleepHours,
  }) => ReminderSettings(
    enabled: enabled ?? this.enabled,
    water: water ?? this.water,
    movement: movement ?? this.movement,
    sleep: sleep ?? this.sleep,
    dailyReview: dailyReview ?? this.dailyReview,
    trendAlerts: trendAlerts ?? this.trendAlerts,
    waterMinute: waterMinute ?? this.waterMinute,
    movementMinute: movementMinute ?? this.movementMinute,
    sleepMinute: sleepMinute ?? this.sleepMinute,
    reviewMinute: reviewMinute ?? this.reviewMinute,
    restingHeartRateChange:
        restingHeartRateChange ?? this.restingHeartRateChange,
    minimumSleepHours: minimumSleepHours ?? this.minimumSleepHours,
  );

  factory ReminderSettings.fromProfile(Map<String, String> profile) {
    bool flag(String key, bool fallback) =>
        profile[key] == null ? fallback : profile[key] == 'true';
    int integer(String key, int fallback) =>
        int.tryParse(profile[key] ?? '') ?? fallback;
    double number(String key, double fallback) =>
        double.tryParse(profile[key] ?? '') ?? fallback;
    return ReminderSettings(
      enabled: flag('notifications.enabled', false),
      water: flag('notifications.water', true),
      movement: flag('notifications.movement', true),
      sleep: flag('notifications.sleep', true),
      dailyReview: flag('notifications.dailyReview', true),
      trendAlerts: flag('notifications.trendAlerts', true),
      waterMinute: integer('notifications.waterMinute', 14 * 60),
      movementMinute: integer('notifications.movementMinute', 16 * 60),
      sleepMinute: integer('notifications.sleepMinute', 22 * 60),
      reviewMinute: integer('notifications.reviewMinute', 20 * 60),
      restingHeartRateChange: number(
        'notifications.restingHeartRateChange',
        15,
      ),
      minimumSleepHours: number('notifications.minimumSleepHours', 6),
    );
  }

  Map<String, String> applyTo(Map<String, String> profile) => {
    ...profile,
    'notifications.enabled': '$enabled',
    'notifications.water': '$water',
    'notifications.movement': '$movement',
    'notifications.sleep': '$sleep',
    'notifications.dailyReview': '$dailyReview',
    'notifications.trendAlerts': '$trendAlerts',
    'notifications.waterMinute': '$waterMinute',
    'notifications.movementMinute': '$movementMinute',
    'notifications.sleepMinute': '$sleepMinute',
    'notifications.reviewMinute': '$reviewMinute',
    'notifications.restingHeartRateChange': '$restingHeartRateChange',
    'notifications.minimumSleepHours': '$minimumSleepHours',
  };
}
