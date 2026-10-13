/// What the VM says about the fields of one object: which classes declare them,
/// and what they hold, as text.
///
/// It is how LeakSentry tells a `State` that was disposed from one that is on
/// screen, without a heap snapshot: a disposed `State` has no element, a
/// disposed `AnimationController` has no ticker, and so on.
class FieldFacts {
  const FieldFacts({this.declaringClasses = const {}, this.values = const {}});

  /// The classes that declare a field of the object, its own and every class it
  /// inherits from: `{'State', '_PageState'}`.
  final Set<String> declaringClasses;

  /// What each field holds, by the class that declares it and its name:
  /// `State._element` is `null`. A number, a bool or a string is its text; any
  /// other object is the name of its class.
  final Map<String, String> values;

  /// Whether [className] declares a field of the object, which is to say whether
  /// the object is one.
  bool declares(String className) => declaringClasses.contains(className);

  /// What the field [field] of [owner] holds, or null if there is no such field.
  String? valueOf(String owner, String field) => values['$owner.$field'];
}
