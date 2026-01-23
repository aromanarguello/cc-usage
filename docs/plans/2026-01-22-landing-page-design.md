# Claude Code Usage Landing Page Design

## Overview
Landing page for claudecodeusage.com - a simple, single-page Next.js site to collect emails and provide download access.

## Location
Separate directory: `~/Code/claudecodeusage-site` (not in cc-usage repo)

## Tech Stack
- Next.js 14 (App Router)
- Tailwind CSS
- Google Sheets API for email collection
- Vercel for hosting

## Brand Guidelines (Anthropic)
**Colors:**
- Dark: `#141413` - Primary text
- Light: `#faf9f5` - Background
- Mid Gray: `#b0aea5` - Secondary text
- Light Gray: `#e8e6dc` - Subtle backgrounds
- Orange: `#d97757` - Primary accent (CTA buttons)
- Blue: `#6a9bcc` - Secondary accent
- Green: `#788c5d` - Tertiary accent

**Typography:**
- Headings: Poppins
- Body: Lora

## Page Structure

### Hero Section
- **Eyebrow**: "FOR CLAUDE CODE USERS"
- **Headline**: "Track your usage from the menu bar"
- **Description**: "See your 5-hour and weekly limits at a glance. 100% local—your data never leaves your Mac."
- **CTA**: Email input field + "Get for Mac" button
- **Below CTA**: "Free and open source" with GitHub link
- **Right side**: App screenshot in macOS window mockup

### Trust Indicators (subtle, below hero)
- 100% Local
- Open Source
- macOS Native

### Footer
- GitHub link
- "Made by [name]"

## Email Flow
1. User enters email
2. Email saved to Google Sheets via API route
3. Download starts immediately (redirect to GitHub release .dmg)

## Key Messages
1. **Privacy**: "Your data never leaves your Mac"
2. **Transparency**: "Free and open source"
