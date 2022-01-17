import 'dart:convert';
import 'dart:io';

import 'package:cli_pkg/src/standalone.dart';
import 'package:crypto/crypto.dart';
import 'package:grinder/grinder.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import 'config_variable.dart';
import 'github.dart';
import 'info.dart';
import 'utils.dart';

/// The GitHub repository slug (for example, `username/repo`) of the PPA
/// repository for this package.
///
/// This must be set explicitly.
final debianRepo = InternalConfigVariable.fn<String>(
    () => fail("pkg.debianRepo must be set to deploy to PPA repository."));

/// The email address for signing the package.
final signingEmail = InternalConfigVariable.fn<String>(
    () => fail("pkg.signingEmail must be set to deploy to PPA repository."));

/// The data needed to generate the Control file in the Debian package.
///
/// This must be set explicitly.
final controlData = InternalConfigVariable.fn<String>(() => fail(
    "pkg.controlData must be set to generate Control file for the package."));

/// Whether [addDebianTasks] has been called yet.
var _addedDebianTasks = false;

/// Adds the task to create and upload the new package to the PPA.
void addDebianTasks() {
  if (!Platform.isLinux) {
    fail("Platform must be linux for this task.");
  }

  if (_addedDebianTasks) return;
  _addedDebianTasks = true;

  freezeSharedVariables();
  debianRepo.freeze();
  signingEmail.freeze();

  addTask(GrinderTask('pkg-debian-update',
      taskFunction: () => _update(),
      description: 'Update the Debian package.'));
}

/// Releases the source code in a Debian package and
/// updates the PPA repository with the new package.
Future<void> _update() async {
  final String packageName = standaloneName.value + "_" + version.toString();

  var repo =
      await cloneOrPull(url("https://github.com/$debianRepo.git").toString());

  await _createDebianPackage(repo, packageName);
  await _releaseNewPackage(repo);
  // TODO: Function to Upload the package to the Git repository.
}

/// Creates a Debian package from the source code.
Future<void> _createDebianPackage(String repo, String packageName) async {
  String debianDir = await _createPackageDirectory(repo, packageName);

  _generateControlFile(debianDir);
  _generateExecutableFiles(debianDir);
  // Pack the files into a .deb file
  run("dpkg-deb", arguments: ["--build", packageName], workingDirectory: repo);
  _removeDirectory(debianDir);
}

/// Delete the Directory with path [directory].
Future<void> _removeDirectory(String directory) async {
  var result = await Process.run("rm", ["-r", directory]);
  if (result.exitCode != 0) {
    fail('Unable to remove the directory\n${result.stderr}');
  }
}

/// Scans the PPA [repo] for new packages and updates the
/// release files, also signing them.
Future<void> _releaseNewPackage(String repo) async {
  await _updatePackagesFile(repo);
  await _updateReleaseFile(repo);
  await _updateReleaseGPGFile(repo);
  await _updateInReleaseFile(repo);
}

/// Create the directory `repo/packageName` and relevant subfolders for the
/// debian package.
///
/// Returns the path of created folder.
Future<String> _createPackageDirectory(String repo, String packageName) async {
  String debianDir = p.join(repo, packageName);
  await Directory('$debianDir/DEBIAN').create(recursive: true);
  await Directory('$debianDir/usr/local/bin').create(recursive: true);
  return debianDir;
}

/// Generate the executable files from the map [executables] which contains the
/// executable name as key and the path to the corresponding Dart file as value.
void _generateExecutableFiles(String debianDir) {
  final executablePath = p.join(debianDir, "usr", "local", "bin");
  executables.value.forEach((name, path) {
    run('dart', arguments: [
      'compile',
      'exe',
      path,
      for (var entry in environmentConstants.value.entries)
        '-D${entry.key}=${entry.value}',
      '--output',
      p.join(executablePath, name)
    ]);
  });
}

/// Generate the control file for the Debian package.
void _generateControlFile(String debianDir) {
  var controlFilePath = p.join(debianDir, "DEBIAN", "control");
  writeString(controlFilePath, controlData.value);
}

/// Scan for new .deb packages in the [repo] and update the `Packages` file.
Future<void> _updatePackagesFile(String repo) async {
  // Scan for new packages
  String output = run("dpkg-scanpackages",
      arguments: ["--multiversion", "."], workingDirectory: repo);
  // Write the stdout to the file
  writeString(p.join(repo, 'Packages'), output);
  // Force Compress the Packages file
  run("gzip", arguments: ["-k", "-f", "Packages"], workingDirectory: repo);
}

/// Generate the Release index for the PPA.
Future<void> _updateReleaseFile(String repo) async {
  String output = run("apt-ftparchive",
      arguments: ["release", "."], workingDirectory: repo);
  writeString(p.join(repo, 'Release'), output);
}

/// Sign the Release file with the GPG key.
Future<void> _updateReleaseGPGFile(String repo) async {
  String output = run("gpg",
      arguments: [
        "--default-key",
        signingEmail.value,
        "-abs",
        "-o",
        "-",
        "Release",
      ],
      workingDirectory: repo);
  writeString(p.join(repo, 'Release.gpg'), output);
}

/// Update the InRelease file with the new index and keys.
Future<void> _updateInReleaseFile(String repo) async {
  String output = run("gpg",
      arguments: [
        "--default-key",
        signingEmail.value,
        "--clearsign",
        "-o",
        "-",
        "Release",
      ],
      workingDirectory: repo);
  writeString(p.join(repo, 'InRelease'), output);
}
