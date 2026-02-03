# Change: Add Session Persistence

## Why

Users lose their entire conversation history when closing Neovim or restarting
their editor. This forces them to recreate context manually and restart
conversations from scratch, reducing productivity. Session persistence enables
users to restore previous conversations and continue work exactly where they
left off.

## What Changes

- Add `ChatHistory` class to hold conversation messages in memory
- Store chat history to disk **asynchronously** on turn completion (non-blocking
  I/O via `vim.uv.fs_*`)
- Store session metadata: session ID, title (first message), message array
- Store files in project-specific folders:
  `<cache>/agentic/sessions/<normalized_path_hash>/<session_id>.json`
  - Folder name: normalized CWD path + hash suffix (e.g.,
    `Users_me_projects_myapp_123456`)
  - One folder per project, multiple sessions per folder
- Implement message replay feature to populate chat buffer from saved JSON
- Expose `restore_session(session_id)` method in `init.lua`
  - If called without session_id, list available sessions via `vim.ui.select()`
  - Format: `<human_readable_date> - <title>`
  - Conflict detection: prompt if current tabpage has active session
- Minimal invasive changes - only SessionManager creates/updates ChatHistory

**Note:** This is foundational work for future provider/model switching, but
this proposal focuses only on session restoration for a single provider.

## Impact

- Affected specs: New capability `session-persistence`
- Affected code:
  - `lua/agentic/init.lua` - Add `restore_session(session_id)` with session
    discovery and conflict handling
  - `lua/agentic/session_manager.lua` - Creates ChatHistory, triggers async
    save, implements replay
  - New: `lua/agentic/chat_history.lua` - Manages message storage, async I/O,
    path generation
