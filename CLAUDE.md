# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Windows tools repository that appears to be in its initial setup phase. The repository is currently empty and ready for development.

## Development Setup

Since this is a new repository, the development workflow and commands will depend on the type of Windows tools being developed. Common patterns for Windows development include:

- **PowerShell modules**: Use `Import-Module` for testing, `Test-ModuleManifest` for validation
- **Python scripts**: Use `python -m pytest` for testing, `python -m pip install -r requirements.txt` for dependencies
- **C# applications**: Use `dotnet build`, `dotnet test`, `dotnet run`
- **Batch/CMD scripts**: Direct execution for testing

## Architecture Notes

The repository structure and architecture will be established as development progresses. Key considerations for Windows tools:

- Cross-platform compatibility (PowerShell Core vs Windows PowerShell)
- Windows version compatibility requirements
- Administrative privileges requirements
- Dependency management strategy

## Future Development

As the repository grows, this file should be updated with:
- Specific build and test commands
- Project structure and component organization
- Windows-specific deployment considerations
- Any special development environment requirements