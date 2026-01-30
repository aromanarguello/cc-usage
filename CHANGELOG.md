# Changelog

All notable changes to Claude Usage Tracker will be documented in this file.

## [1.12.0] - 2026-01-30

### Improved
- **Wake Recovery:** Fresh data appears within seconds after Mac wakes (down from 45+ seconds)
- **Pre-Sleep Caching:** Proactively warms credential cache before sleep for faster wake recovery
- **Network Resilience:** Automatic retry with exponential backoff for transient network failures
- **Smarter Preflight:** Better decisions about when automatic refresh can proceed silently

### Technical
- Reduced wake delay from 45s to 5s
- Added token cache timestamp tracking for freshness decisions
- Added `warmCacheForSleep()` for proactive credential caching
- Added `hasWarmCachedToken()` for smarter preflight checks
- Retry logic: 3 attempts with 2s/4s/8s delays for network errors
