/// Something that starts watching objects when installed.
abstract interface class InstallableWatcher {
  void install();

  void uninstall();
}
