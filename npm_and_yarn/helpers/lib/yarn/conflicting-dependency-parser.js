/* Conflicting dependency parser for yarn
 *
 * Inputs:
 *  - directory containing a package.json and a yarn.lock
 *  - dependency name
 *  - target dependency version
 *
 * Outputs:
 *  - An array of objects with conflicting dependencies
 */

const semver = require("semver");
const { parse } = require("./lockfile-parser");
const { LOCKFILE_ENTRY_REGEX } = require("./helpers");

async function findConflictingDependencies(directory, depName, targetVersion) {
  var parents = [];

  const json = await parse(directory);

  Object.entries(json).forEach(([entry, pkg]) => {
    if (entry.match(LOCKFILE_ENTRY_REGEX) && pkg.dependencies) {
      Object.entries(pkg.dependencies).forEach(([subDepName, spec]) => {
        if (subDepName === depName && !semver.satisfies(targetVersion, spec)) {
          const [_, parentDepName] = entry.match(LOCKFILE_ENTRY_REGEX);
          parents.push({
            name: parentDepName,
            version: pkg.version,
            requirement: spec,
          });
        }
      });
    }
  });

  return parents;
}

module.exports = { findConflictingDependencies };
