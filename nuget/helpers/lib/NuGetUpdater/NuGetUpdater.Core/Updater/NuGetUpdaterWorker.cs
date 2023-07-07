﻿using System.IO;
using System.Threading.Tasks;

namespace NuGetUpdater.Core;

public partial class NuGetUpdaterWorker
{
    private readonly Logger _logger;

    public NuGetUpdaterWorker(Logger logger)
    {
        _logger = logger;
    }

    public async Task RunAsync(string repoRootPath, string filePath, string dependencyName, string previousDependencyVersion, string newDependencyVersion)
    {
        MSBuildHelper.RegisterMSBuild();

        if (!Path.IsPathRooted(filePath) || !File.Exists(filePath))
        {
            filePath = Path.GetFullPath(Path.Join(repoRootPath, filePath));
        }

        var extension = Path.GetExtension(filePath).ToLowerInvariant();
        switch (extension)
        {
            case ".sln":
                await RunForSolutionAsync(repoRootPath, filePath, dependencyName, previousDependencyVersion, newDependencyVersion);
                break;
            case ".proj":
                await RunForProjFileAsync(repoRootPath, filePath, dependencyName, previousDependencyVersion, newDependencyVersion);
                break;
            case ".csproj":
            case ".fsproj":
            case ".vbproj":
                await RunForProjectAsync(repoRootPath, filePath, dependencyName, previousDependencyVersion, newDependencyVersion);
                break;
        }
    }

    private async Task RunForSolutionAsync(string repoRootPath, string solutionPath, string dependencyName, string previousDependencyVersion, string newDependencyVersion)
    {
        _logger.Log($"Running for solution [{Path.GetRelativePath(repoRootPath, solutionPath)}]");
        var projectPaths = MSBuildHelper.GetProjectPathsFromSolution(solutionPath);
        foreach (var projectPath in projectPaths)
        {
            await RunForProjectAsync(repoRootPath, projectPath, dependencyName, previousDependencyVersion, newDependencyVersion);
        }
    }

    private async Task RunForProjFileAsync(string repoRootPath, string projFilePath, string dependencyName, string previousDependencyVersion, string newDependencyVersion)
    {
        _logger.Log($"Running for proj file [{Path.GetRelativePath(repoRootPath, projFilePath)}]");
        var projectFilePaths = MSBuildHelper.GetProjectPathsFromProject(projFilePath);
        foreach (var projectFullPath in projectFilePaths)
        {
            // If there is some MSBuild logic that needs to run to fully resolve the path skip the project
            if (File.Exists(projectFullPath))
            {
                await RunForProjectAsync(repoRootPath, projectFullPath, dependencyName, previousDependencyVersion, newDependencyVersion);
            }
        }
    }

    private async Task RunForProjectAsync(string repoRootPath, string projectPath, string dependencyName, string previousDependencyVersion, string newDependencyVersion)
    {
        _logger.Log($"Running for project [{projectPath}]");

        if (PackageConfigUpdater.HasProjectConfigFile(projectPath))
        {
            await PackageConfigUpdater.UpdateDependencyAsync(projectPath, dependencyName, previousDependencyVersion, newDependencyVersion, _logger);
        }
        else
        {
            await SdkPackageUpdater.UpdateDependencyAsync(repoRootPath, projectPath, dependencyName, previousDependencyVersion, newDependencyVersion, _logger);
        }

        _logger.Log("Update complete.");
    }
}