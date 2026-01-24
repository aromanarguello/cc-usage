# API Key Authentication Improvements Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Address code review feedback for the manual API key feature - add UI to clear/update API keys, fix architectural inconsistencies, and improve user feedback.

**Architecture:** Expose `CredentialService` through `UsageViewModel` for consistent dependency injection. Add settings gear icon in header that opens a sheet with API key management. Show auth method indicator in footer when using manual key.

**Tech Stack:** SwiftUI, macOS Keychain Services, Swift actors

---

## Task 1: Expose CredentialService Through ViewModel

**Files:**
- Modify: `Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift`
- Modify: `Sources/ClaudeCodeUsage/Views/UsagePopoverView.swift`

**Step 1: Add credential methods to UsageViewModel**

In `UsageViewModel.swift`, add these methods and properties:

```swift
// Add near the top of the class, after existing properties
private let credentialService: CredentialService

// Add computed property
var isUsingManualAPIKey: Bool {
    get async {
        return await credentialService.hasManualAPIKey()
    }
}

// Add methods
func saveManualAPIKey(_ key: String) async throws {
    try await credentialService.saveManualAPIKey(key)
}

func deleteManualAPIKey() async throws {
    try await credentialService.deleteManualAPIKey()
}

func validateAPIKeyFormat(_ key: String) async -> Bool {
    return await credentialService.validateAPIKeyFormat(key)
}
```

**Step 2: Update UsageViewModel initializer**

Modify the init to store the credential service:

```swift
init(apiService: UsageAPIService, credentialService: CredentialService) {
    self.apiService = apiService
    self.credentialService = credentialService
}
```

**Step 3: Update UsagePopoverView to use viewModel**

Remove the private `credentialService` property from `UsagePopoverView.swift` (line 19):

```swift
// DELETE THIS LINE:
private let credentialService = CredentialService()
```

Update `saveAPIKey()` function to use viewModel:

```swift
private func saveAPIKey() {
    keyError = nil
    isSavingKey = true

    Task {
        do {
            try await viewModel.saveManualAPIKey(apiKeyInput)

            await MainActor.run {
                showKeySaved = true
                isSavingKey = false
            }

            try? await Task.sleep(nanoseconds: 800_000_000)

            await MainActor.run {
                showKeySaved = false
                apiKeyInput = ""
            }

            await viewModel.refresh()

        } catch CredentialError.invalidAPIKeyFormat {
            await MainActor.run {
                keyError = "Invalid API key format. Keys start with sk-ant-"
                isSavingKey = false
            }
        } catch {
            await MainActor.run {
                keyError = "Failed to save: \(error.localizedDescription)"
                isSavingKey = false
            }
        }
    }
}
```

**Step 4: Update AppDelegate initialization**

In `AppDelegate.swift`, update the view model creation:

```swift
let viewModel = UsageViewModel(apiService: apiService, credentialService: credentialService)
```

**Step 5: Update Preview**

In `UsagePopoverView.swift`, update the preview:

```swift
#Preview {
    let credentialService = CredentialService()
    let apiService = UsageAPIService(credentialService: credentialService)
    let viewModel = UsageViewModel(apiService: apiService, credentialService: credentialService)
    return UsagePopoverView(viewModel: viewModel)
}
```

**Step 6: Build and verify**

Run: `swift build`
Expected: Build succeeds with no new errors

**Step 7: Commit**

```bash
git add Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift Sources/ClaudeCodeUsage/Views/UsagePopoverView.swift Sources/ClaudeCodeUsage/App/AppDelegate.swift
git commit -m "refactor: expose CredentialService through UsageViewModel

Fixes architectural issue where UsagePopoverView created its own
CredentialService instance instead of using dependency injection.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Task 2: Add Settings Sheet with API Key Management

**Files:**
- Create: `Sources/ClaudeCodeUsage/Views/APIKeySettingsView.swift`
- Modify: `Sources/ClaudeCodeUsage/Views/UsagePopoverView.swift`

**Step 1: Create APIKeySettingsView**

Create new file `Sources/ClaudeCodeUsage/Views/APIKeySettingsView.swift`:

```swift
import SwiftUI

struct APIKeySettingsView: View {
    @Bindable var viewModel: UsageViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var hasManualKey = false
    @State private var isDeleting = false
    @State private var showDeleteConfirmation = false
    @State private var deleteError: String? = nil

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("API Key Settings")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            if hasManualKey {
                // Manual key is configured
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "key.fill")
                            .foregroundColor(.orange)
                        Text("Manual API Key")
                            .fontWeight(.medium)
                        Spacer()
                        Text("Active")
                            .font(.caption)
                            .foregroundColor(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    Text("You're using a manually configured Anthropic API key stored in Keychain.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let error = deleteError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    Button(action: { showDeleteConfirmation = true }) {
                        HStack {
                            if isDeleting {
                                ProgressView()
                                    .scaleEffect(0.6)
                            } else {
                                Image(systemName: "trash")
                            }
                            Text("Remove API Key")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.15))
                        .foregroundColor(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(isDeleting)
                }
            } else {
                // Using OAuth
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.key.fill")
                            .foregroundColor(.blue)
                        Text("Claude Code OAuth")
                            .fontWeight(.medium)
                        Spacer()
                        Text("Active")
                            .font(.caption)
                            .foregroundColor(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    Text("Using credentials from Claude Code. No manual configuration needed.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer()
        }
        .padding()
        .frame(width: 280, height: 200)
        .background(.ultraThinMaterial)
        .task {
            hasManualKey = await viewModel.isUsingManualAPIKey
        }
        .alert("Remove API Key?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                deleteAPIKey()
            }
        } message: {
            Text("This will remove your manual API key. The app will try to use Claude Code OAuth credentials instead.")
        }
    }

    private func deleteAPIKey() {
        isDeleting = true
        deleteError = nil

        Task {
            do {
                try await viewModel.deleteManualAPIKey()
                await MainActor.run {
                    hasManualKey = false
                    isDeleting = false
                }
                // Refresh to attempt OAuth
                await viewModel.refresh()
            } catch {
                await MainActor.run {
                    deleteError = "Failed to remove: \(error.localizedDescription)"
                    isDeleting = false
                }
            }
        }
    }
}
```

**Step 2: Add settings button and sheet to UsagePopoverView**

Add state variable near other `@State` declarations:

```swift
@State private var showSettings = false
```

Update the header section in `body` to add settings gear:

```swift
// Header
HStack {
    Text("Claude Usage")
        .font(.headline)

    Button(action: { showSettings = true }) {
        Image(systemName: "gearshape")
            .foregroundColor(.secondary)
    }
    .buttonStyle(.plain)

    Spacer()
    if let subscription = viewModel.usageData?.subscription {
        Text(subscription)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.orange)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
.padding()
```

Add the sheet modifier after the existing `.alert` modifiers (before the closing brace of `body`):

```swift
.sheet(isPresented: $showSettings) {
    APIKeySettingsView(viewModel: viewModel)
}
```

**Step 3: Build and verify**

Run: `swift build`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add Sources/ClaudeCodeUsage/Views/APIKeySettingsView.swift Sources/ClaudeCodeUsage/Views/UsagePopoverView.swift
git commit -m "feat: add settings sheet with API key management

Users can now:
- See which auth method is active (OAuth vs manual key)
- Remove their manual API key to revert to OAuth

Accessible via gear icon in the header.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Task 3: Add Auth Method Indicator in Footer

**Files:**
- Modify: `Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift`
- Modify: `Sources/ClaudeCodeUsage/Views/UsagePopoverView.swift`

**Step 1: Add published property to track auth method**

In `UsageViewModel.swift`, add a published property:

```swift
@Published var usingManualKey: Bool = false
```

Update the `refresh()` method to check auth method after successful fetch. Add this at the end of the successful path:

```swift
// Check auth method
self.usingManualKey = await credentialService.hasManualAPIKey()
```

**Step 2: Update footer to show auth indicator**

In `UsagePopoverView.swift`, update the footer section. Replace the existing footer HStack:

```swift
// Footer
HStack {
    if viewModel.errorMessage != nil, viewModel.usageData != nil {
        Image(systemName: "exclamationmark.circle")
            .foregroundColor(.orange)
            .font(.caption)
    }

    if viewModel.usingManualKey {
        HStack(spacing: 3) {
            Image(systemName: "key.fill")
                .font(.caption2)
            Text("API Key")
                .font(.caption2)
        }
        .foregroundColor(.orange)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.orange.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    Text("Updated \(viewModel.timeSinceUpdate)")
        .font(.caption)
        .foregroundColor(.secondary)

    Spacer()

    Button(action: {
        Task { await viewModel.refresh() }
    }) {
        if viewModel.isLoading {
            ProgressView()
                .scaleEffect(0.6)
        } else {
            Image(systemName: "arrow.clockwise")
        }
    }
    .buttonStyle(.plain)
    .disabled(viewModel.isLoading)
}
.padding(.horizontal)
.padding(.vertical, 8)
```

**Step 3: Build and verify**

Run: `swift build`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift Sources/ClaudeCodeUsage/Views/UsagePopoverView.swift
git commit -m "feat: show auth method indicator in footer

Displays 'API Key' badge when using manual authentication,
helping users understand which auth method is active.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Task 4: Fix Placeholder Text

**Files:**
- Modify: `Sources/ClaudeCodeUsage/Views/UsagePopoverView.swift`

**Step 1: Update placeholder to be more generic**

Find and replace the placeholder text in `apiKeyConfigurationView`:

```swift
// Change from:
TextField("sk-ant-api03-...", text: $apiKeyInput)
// and
SecureField("sk-ant-api03-...", text: $apiKeyInput)

// Change to:
TextField("sk-ant-...", text: $apiKeyInput)
// and
SecureField("sk-ant-...", text: $apiKeyInput)
```

**Step 2: Build and verify**

Run: `swift build`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Sources/ClaudeCodeUsage/Views/UsagePopoverView.swift
git commit -m "fix: use generic API key placeholder

Changed from 'sk-ant-api03-...' to 'sk-ant-...' since
Anthropic keys can have various version prefixes.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Task 5: Build Release and Test

**Files:**
- Modify: `Resources/Info.plist`
- Modify: `scripts/build.sh`

**Step 1: Bump version to 1.6.0**

In `Resources/Info.plist`, update:

```xml
<key>CFBundleShortVersionString</key>
<string>1.6.0</string>
```

In `scripts/build.sh`, update:

```bash
VERSION="1.6.0"
```

**Step 2: Build release app**

Run: `./scripts/build.sh`
Expected: Build succeeds, app bundle created at `release/ClaudeCodeUsage.app`

**Step 3: Manual test checklist**

- [ ] Open app, verify normal usage view displays
- [ ] Click gear icon, verify settings sheet opens
- [ ] Settings shows "Claude Code OAuth" as active
- [ ] Close settings, verify footer shows "Updated X ago" (no API Key badge)
- [ ] In Keychain Access, delete "Claude Code-credentials" entry temporarily
- [ ] Refresh app, verify API key input appears
- [ ] Enter valid API key, verify "Saved!" animation
- [ ] Verify usage data loads with manual key
- [ ] Verify footer now shows "API Key" badge
- [ ] Open settings, verify "Manual API Key" is active
- [ ] Click "Remove API Key", verify confirmation dialog
- [ ] Confirm removal, verify app tries OAuth again
- [ ] Restore "Claude Code-credentials" in Keychain

**Step 4: Commit version bump**

```bash
git add Resources/Info.plist scripts/build.sh
git commit -m "chore: bump version to 1.6.0

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Summary

| Task | Description | Estimated Steps |
|------|-------------|-----------------|
| 1 | Expose CredentialService through ViewModel | 7 |
| 2 | Add Settings Sheet with API Key Management | 4 |
| 3 | Add Auth Method Indicator in Footer | 4 |
| 4 | Fix Placeholder Text | 3 |
| 5 | Build Release and Test | 4 |

**Total:** 22 steps across 5 tasks
