#!/usr/bin/env powershell

# Configure git with the specified credentials
git config user.name 'rhshourav'
git config user.email 'rhshourav02@gmail.com'

# Stage all untracked files
git add IMPLEMENTATION_REPORT.md REFACTORING_SPEC.md REFACTORING_SUMMARY.md windowsScripts-Refactored.ps1

# Create a commit with appropriate message
git commit -m "Add PowerShell menu refactoring specifications and implementation

- Implement hierarchical menu structure from flat 26-item menu
- Add 9 main menu items + 3 submenu shortcuts
- Include navigation, breadcrumb, and state management
- Preserve all original functionality (elevation, scripts, system status)
- Add comprehensive documentation and specifications
- All success criteria verified (navigation, performance, security)

Co-authored-by: Claude <noreply@anthropic.com>"

# Push to origin
$remote = git remote get-url origin
git push $remote main

Write-Host 'Files uploaded to GitHub with specified credentials:'
Write-Host '  Username: rhshourav'
Write-Host '  Email: rhshourav02@gmail.com'
Write-Host 'Repository: $remote'
