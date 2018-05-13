<?php

declare(strict_types=1);

namespace Dependabot\PHP;

use Composer\Factory;
use Composer\Installer;
use Composer\Package\PackageInterface;

class UpdateChecker
{
    public static function getLatestResolvableVersion(array $args): ?string
    {
        [$workingDirectory, $dependencyName, $gitCredentials, $registryCredentials] = $args;

        $io = new ExceptionIO();
        $composer = Factory::create($io, $workingDirectory . '/composer.json');
        $config = $composer->getConfig();
        $httpBasicCredentials = [];

        foreach ($gitCredentials as &$cred) {
            $httpBasicCredentials[$cred['host']] = [
                'username' => $cred['username'],
                'password' => $cred['password'],
            ];
        }

        foreach ($registryCredentials as &$cred) {
            $httpBasicCredentials[$cred['registry']] = [
                'username' => $cred['username'],
                'password' => $cred['password'],
            ];
        }

        if ($httpBasicCredentials) {
            $config->merge(
                [
                    'config' => [
                        'http-basic' => $httpBasicCredentials,
                    ],
                ]
            );
            $io->loadConfiguration($config);
        }

        $installationManager = new DependabotInstallationManager();
        $install = new Installer(
            $io,
            $config,
            $composer->getPackage(),
            $composer->getDownloadManager(),
            $composer->getRepositoryManager(),
            $composer->getLocker(),
            $installationManager,
            $composer->getEventDispatcher(),
            $composer->getAutoloadGenerator()
        );

        // For all potential options, see UpdateCommand in composer
        $install
            ->setDryRun(true)
            ->setUpdate(true)
            ->setDevMode(true)
            ->setUpdateWhitelist([$dependencyName])
            ->setExecuteOperations(false)
            ->setDumpAutoloader(false)
            ->setRunScripts(false)
            ->setIgnorePlatformRequirements(true);

        $install->run();

        $installedPackages = $installationManager->getInstalledPackages();

        $updatedPackage = current(array_filter($installedPackages, function (PackageInterface $package) use ($dependencyName) {
            return $package->getName() == $dependencyName;
        }));

        // We found the package in the list of updated packages. Return its version.
        if ($updatedPackage) {
            return preg_replace('/^([v])/', '', $updatedPackage->getPrettyVersion());
        }

        // We didn't find the package in the list of updated packages. Check if
        // it was replaced by another package (in which case we can ignore).
        foreach ($installedPackages as $package) {
            foreach ($package->getReplaces() as $link) {
                if ($link->getTarget() == $dependencyName) {
                    return null;
                }
            }
        }

        throw new \RuntimeException('Package not found in updated packages!');
    }
}
