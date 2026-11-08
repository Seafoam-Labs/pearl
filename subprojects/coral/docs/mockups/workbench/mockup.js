"use strict";

// Everything below is an in-memory fixture. No network, storage, shell, or disk APIs.
const $ = (id) => document.getElementById(id);
const ui = {
  sidebar: window.innerWidth > 700,
  agent: window.innerWidth > 1100,
  panel: true,
  view: "explorer",
  panelTab: "problems",
  diff: null,
};
const INTRO = "A little context, then a careful change.\n\nI can inspect a sample buffer and propose a patch. You approve the read, review the diff, and decide what lands. Nothing is staged automatically.\n\nThis is a deterministic offline agent, not a connected model.";
const MAIN_HEAD = `const std = @import("std");
const workspace = @import("workspace.zig");

pub fn main() !void {
    const name = "Coral";
    std.debug.print("Hello, {s}\\n", .{name});

    // Keep workspace ownership explicit.
    const roots = workspace.defaultRoots();
    for (roots) |root| {
        std.debug.print("root: {s}\\n", .{root});
    }
}

test "workspace has a root" {
    const roots = workspace.defaultRoots();
    try std.testing.expect(roots.len > 0);
}
`;
const WORKSPACE = `const std = @import("std");

pub fn defaultRoots() []const []const u8 {
    return &.{ "coral", "shared-ui" };
}

pub const Workspace = struct {
    name: []const u8,
    roots: []const []const u8,

    pub fn rootCount(self: Workspace) usize {
        return self.roots.len;
    }
};

test "default roots are independent" {
    try std.testing.expectEqual(@as(usize, 2), defaultRoots().len);
}
`;
const THEME_HEAD = `pub const Palette = struct {
    background: u32 = 0x18191c,
    surface: u32 = 0x1e2024,
    accent: u32 = 0xc49b91,
    foreground: u32 = 0xd6d7dc,
};

pub const spacing = struct {
    pub const compact = 6;
    pub const normal = 12;
};
`;
let threadSequence = 0;
function makeThread() {
  return {
    id: ++threadSequence, title: "A careful first pass", draft: "",
    model: "Coral Local · fixture", profile: "edit",
    messages: [{ role: "agent", text: INTRO }], task: null,
  };
}
function makeFile(root, path, head, text = head) {
  return { id: `${root}/${path}`, root, path, head, index: head, text, saved: text, revision: 0 };
}
function makeWorkspace(id, name, root, shared) {
  const files = [
    makeFile(root, "src/main.zig", MAIN_HEAD, MAIN_HEAD
      .replace('const name = "Coral";', `const name = "${name} Workbench";`)
      .replace('std.debug.print("Hello,', 'std.debug.prnit("Hello,')
      .replace("roots.len > 0", "roots.len >= 2")),
    makeFile(root, "src/workspace.zig", WORKSPACE),
    makeFile(root, "build.zig", `const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "coral",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);
}
`),
    makeFile(root, "README.md", `# ${name}\n\nA small, intentional editor for Pearl.\n\n## Workspace\n\n- Explicit roots and buffer ownership\n- Reviewable agent changes\n- Staging that never includes unreviewed edits\n\nThis document is an editable in-memory fixture.\n`),
    makeFile(shared, "src/palette.zig", THEME_HEAD, THEME_HEAD.replace("0xc49b91", "0xe5a08e")),
    makeFile(shared, "README.md", "# Shared UI\n\nLocal tokens for the Coral workbench.\n"),
  ];
  const thread = makeThread();
  return {
    id, name, roots: [root, shared], files, active: files[0].id,
    tabs: [files[0].id, files[1].id, files[4].id], collapsed: new Set(),
    branches: ["feature/workbench", "main", "review/agent-dock"], branch: "feature/workbench",
    commits: [], commitDraft: "", threads: [thread], threadId: thread.id,
    terminal: ["Coral fixture terminal · no shell is connected.", "Type help for the four supported fixture commands."],
    search: "",
  };
}
const workspaces = [makeWorkspace("coral", "Coral", "coral", "shared-ui"), makeWorkspace("pearl", "Pearl", "pearl", "toolkit")];
let workspace = workspaces[0];
const fileById = (id, ws = workspace) => ws.files.find((file) => file.id === id);
const activeFile = () => fileById(workspace.active);
const activeThread = () => workspace.threads.find((thread) => thread.id === workspace.threadId);
const busy = (task) => task && ["approval", "working", "proposed"].includes(task.status);

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}
function button(text, className, action, label) {
  const node = el("button", className, text);
  node.type = "button";
  if (label) { node.setAttribute("aria-label", label); node.title = label; }
  node.addEventListener("click", action);
  return node;
}
let toastTimer;
function toast(message) {
  clearTimeout(toastTimer);
  $("toast").textContent = message;
  $("toast").hidden = false;
  toastTimer = setTimeout(() => { $("toast").hidden = true; }, 4500);
}
const dialogOpeners = new Map();
function openDialog(id, focusId) {
  const dialog = $(id);
  dialogOpeners.set(dialog, document.activeElement);
  dialog.showModal();
  if (focusId) $(focusId).focus();
}
for (const dialog of document.querySelectorAll("dialog")) {
  dialog.addEventListener("close", () => {
    const opener = dialogOpeners.get(dialog);
    if (opener?.isConnected && (document.activeElement === document.body || dialog.contains(document.activeElement))) opener.focus();
  });
}
for (const closer of document.querySelectorAll("[data-close]")) {
  closer.addEventListener("click", () => $(closer.dataset.close).close());
}
function notice(title, body) {
  $("notice-title").textContent = title;
  $("notice-body").textContent = body;
  openDialog("notice-dialog");
}

// Native modal dialog provides focus containment and Escape dismissal.
let picker = { items: [], filtered: [], selected: 0 };
function openPicker(title, items, placeholder = "Type to filter…") {
  picker = { items, filtered: items, selected: 0 };
  $("picker-title").textContent = title;
  $("picker-input").value = "";
  $("picker-input").placeholder = placeholder;
  renderPicker();
  openDialog("picker-dialog", "picker-input");
}
function renderPicker() {
  const list = $("picker-results");
  list.replaceChildren();
  picker.filtered.forEach((item, index) => {
    const row = button("", `picker-option${index === picker.selected ? " selected" : ""}`, () => choosePicker(index));
    row.id = `picker-option-${index}`;
    row.tabIndex = -1;
    row.setAttribute("role", "option");
    row.setAttribute("aria-selected", String(index === picker.selected));
    row.append(el("span", "", item.label), el("small", "", item.detail || ""));
    list.append(row);
  });
  if (!picker.filtered.length) list.append(el("p", "empty-state", "No matching options."));
  if (picker.filtered.length) $("picker-input").setAttribute("aria-activedescendant", `picker-option-${picker.selected}`);
  else $("picker-input").removeAttribute("aria-activedescendant");
}
function choosePicker(index) {
  const item = picker.filtered[index];
  if (!item) return;
  $("picker-dialog").close();
  item.action();
}
$("picker-input").addEventListener("input", () => {
  const query = $("picker-input").value.toLowerCase().replace(/^>\s*/, "");
  picker.filtered = picker.items.filter((item) => `${item.label} ${item.detail || ""}`.toLowerCase().includes(query));
  picker.selected = 0;
  renderPicker();
});
$("picker-input").addEventListener("keydown", (event) => {
  if (event.key === "ArrowDown" || event.key === "ArrowUp") {
    event.preventDefault();
    const count = picker.filtered.length;
    picker.selected = count ? (picker.selected + (event.key === "ArrowDown" ? 1 : -1) + count) % count : 0;
    renderPicker();
    $(`picker-option-${picker.selected}`)?.scrollIntoView({ block: "nearest" });
  } else if (event.key === "Enter") {
    event.preventDefault();
    choosePicker(picker.selected);
  }
});

function applyLayout() {
  $("workbench").classList.toggle("sidebar-hidden", !ui.sidebar);
  $("workbench").classList.toggle("agent-hidden", !ui.agent);
  $("bottom-panel").hidden = !ui.panel;
  $("sidebar-toggle").setAttribute("aria-pressed", String(ui.sidebar));
  $("agent-toggle").setAttribute("aria-pressed", String(ui.agent));
  $("panel-toggle").setAttribute("aria-pressed", String(ui.panel));
  document.querySelectorAll("[data-view]").forEach((node) => {
    const selected = ui.sidebar && node.dataset.view === ui.view;
    node.classList.toggle("active", selected);
    node.setAttribute("aria-pressed", String(selected));
  });
}
function toggleSidebar(force) {
  ui.sidebar = force ?? !ui.sidebar;
  if (ui.sidebar && window.innerWidth <= 700) ui.agent = false;
  applyLayout();
}
function toggleAgent(force) {
  ui.agent = force ?? !ui.agent;
  if (ui.agent && window.innerWidth <= 700) ui.sidebar = false;
  applyLayout();
  if (ui.agent) $("agent-prompt").focus();
}
function setView(view) {
  ui.view = view;
  toggleSidebar(true);
  $("sidebar-title").textContent = { explorer: "Explorer", search: "Search", git: "Source control" }[view];
  for (const name of ["explorer", "search", "git"]) $(`${name}-view`).hidden = name !== view;
  if (view === "search") { renderSearch(); $("search-input").focus(); }
  if (view === "git") renderGit();
}
function setPanel(tab) {
  ui.panel = true;
  ui.panelTab = tab;
  for (const name of ["problems", "terminal"]) {
    const selected = name === tab;
    $(`${name}-tab`).setAttribute("aria-selected", String(selected));
    $(`${name}-tab`).tabIndex = selected ? 0 : -1;
    $(`${name}-content`).hidden = !selected;
  }
  applyLayout();
}
function toggleTheme() {
  const light = document.body.classList.toggle("light");
  $("theme-toggle").setAttribute("aria-label", `Switch to ${light ? "dark" : "light"} theme`);
}
function renderTree() {
  const tree = $("file-tree");
  tree.replaceChildren();
  $("root-count").textContent = `${workspace.roots.length} roots`;
  for (const root of workspace.roots) {
    const group = el("details");
    group.open = !workspace.collapsed.has(root);
    const summary = el("summary");
    summary.append(el("span", "root-label", root), el("span", "root-kind", "root"));
    group.append(summary);
    group.addEventListener("toggle", () => {
      if (!group.isConnected) return;
      if (group.open) workspace.collapsed.delete(root); else workspace.collapsed.add(root);
    });
    let directory = "";
    for (const file of workspace.files.filter((item) => item.root === root)) {
      const parts = file.path.split("/");
      const parent = parts.length > 1 ? parts.slice(0, -1).join("/") : "";
      if (parent && directory !== parent) group.append(el("div", "folder-label", `⌄  ${parent}`));
      directory = parent;
      const row = button("", `file-button${parent ? "" : " root-file"}${workspace.active === file.id ? " selected" : ""}`, () => openFile(file.id), `Open ${file.id}`);
      if (workspace.active === file.id) row.setAttribute("aria-current", "true");
      row.append(el("span", "file-icon", file.path.endsWith(".zig") ? "Z" : "M↓"), el("span", "file-name", parts.at(-1)));
      if (file.text !== file.head || file.index !== file.head) row.append(el("span", "file-mark", "M"));
      group.append(row);
    }
    tree.append(group);
  }
  const added = workspace.roots.includes("notes-kit");
  $("add-root").disabled = added;
  $("add-root").title = added ? "Sample root already added" : "Add sample root";
}
function renderTabs() {
  $("editor-tabs").replaceChildren();
  for (const id of workspace.tabs) {
    const file = fileById(id);
    const active = id === workspace.active;
    const tab = el("div", `editor-tab${active ? " active" : ""}`);
    const open = button("", "", () => openFile(id), `Open tab ${id}`);
    open.append(el("span", "file-icon", file.path.endsWith(".zig") ? "Z" : "M↓"), el("span", "", file.path.split("/").at(-1)));
    open.setAttribute("aria-pressed", String(active));
    const dirty = file.text !== file.saved;
    const close = button(dirty ? "●" : "×", "tab-close", () => closeTab(id), `Close ${file.path}${dirty ? " (unsaved buffer retained)" : ""}`);
    tab.append(open, close);
    $("editor-tabs").append(tab);
  }
}
function closeTab(id) {
  if (workspace.tabs.length === 1) {
    toast("The last tab stays open in this prototype. Use Quick Open to choose another file.");
    return;
  }
  const index = workspace.tabs.indexOf(id);
  workspace.tabs.splice(index, 1);
  if (workspace.active === id) workspace.active = workspace.tabs[Math.min(index, workspace.tabs.length - 1)];
  ui.diff = null;
  renderWorkspace();
  $("editor").focus();
  if (fileById(id).text !== fileById(id).saved) toast("Tab closed; its unsaved buffer is retained in this memory workspace.");
}
function openFile(id, line, column = 1, length = 0) {
  const file = fileById(id);
  if (!file) return;
  workspace.active = id;
  if (!workspace.tabs.includes(id)) workspace.tabs.push(id);
  ui.diff = null;
  renderTree(); renderTabs(); renderEditor(); renderContext();
  if (window.innerWidth <= 700) { ui.sidebar = false; ui.agent = false; applyLayout(); }
  $("editor").focus();
  if (line) jumpTo(line, column, length);
}
function jumpTo(line, column = 1, length = 0) {
  const editor = $("editor");
  const lines = editor.value.split("\n");
  const start = lines.slice(0, line - 1).reduce((total, value) => total + value.length + 1, 0) + column - 1;
  editor.focus();
  editor.setSelectionRange(start, start + length);
  editor.scrollTop = Math.max(0, (line - 4) * 22);
  editor.scrollLeft = Math.max(0, (column - 20) * 7.3);
  syncScroll(); updateCursor();
}
function renderEditor() {
  const file = activeFile();
  $("editor").value = file.text;
  $("editor").setAttribute("aria-label", `Edit ${file.id}`);
  $("breadcrumb").textContent = file.id.split("/").join("  ›  ");
  $("language-label").textContent = file.path.endsWith(".zig") ? "Zig" : "Markdown";
  $("code-view").hidden = Boolean(ui.diff);
  $("diff-view").hidden = !ui.diff;
  highlight(); renderBufferStatus(); updateCursor();
  if (ui.diff) renderDiff();
}
function highlight() {
  const text = activeFile().text;
  const pre = $("highlight");
  pre.replaceChildren();
  const tokens = /\/\/[^\n]*|"(?:\\.|[^"\\])*"|\b(?:const|pub|fn|return|try|test|for|struct|void|usize|u32|u8)\b|\b(?:0x[\da-fA-F]+|\d+)\b|\bprnit\b/g;
  let last = 0;
  for (const match of text.matchAll(tokens)) {
    pre.append(document.createTextNode(text.slice(last, match.index)));
    const token = match[0];
    const kind = token.startsWith("//") ? "comment" : token.startsWith('"') ? "string" : token === "prnit" ? "error" : /^\d/.test(token) ? "number" : "keyword";
    pre.append(el("span", `token-${kind}`, token));
    last = match.index + token.length;
  }
  pre.append(document.createTextNode(text.slice(last) + "\n"));
  $("line-numbers").textContent = text.split("\n").map((_, i) => i + 1).join("\n") + "\n";
  syncScroll();
}
function syncScroll() {
  $("highlight").scrollTop = $("editor").scrollTop;
  $("highlight").scrollLeft = $("editor").scrollLeft;
  $("line-numbers").scrollTop = $("editor").scrollTop;
}
function updateCursor() {
  const prefix = $("editor").value.slice(0, $("editor").selectionStart);
  const lines = prefix.split("\n");
  $("cursor-position").textContent = `Ln ${lines.length}, Col ${lines.at(-1).length + 1}`;
}
function renderBufferStatus() {
  $("buffer-status").textContent = activeFile().text === activeFile().saved ? "Saved in preview" : "● Unsaved · memory only";
  $("code-action").disabled = !diagnostics().some((item) => item.file.id === workspace.active);
}
function changeText(file, text) {
  if (file.text === text) return;
  file.text = text;
  file.revision += 1;
}
function refreshAfterEdit({ loadEditor = false } = {}) {
  renderTree(); renderTabs(); renderProblems(); renderGit(); renderBufferStatus();
  if (ui.view === "search") renderSearch();
  if (loadEditor) renderEditor(); else highlight();
  markStaleTasks();
}
$("editor").addEventListener("input", () => {
  changeText(activeFile(), $("editor").value);
  refreshAfterEdit(); updateCursor();
});
$("editor").addEventListener("scroll", syncScroll);
$("editor").addEventListener("click", updateCursor);
$("editor").addEventListener("keyup", updateCursor);
$("editor").addEventListener("select", updateCursor);
function savePreview() {
  activeFile().saved = activeFile().text;
  renderTabs(); renderBufferStatus();
  toast("Saved this buffer in memory only. Git staging is unchanged; reload resets everything.");
}
function diagnostics() {
  const result = [];
  for (const file of workspace.files) {
    if (!file.path.endsWith(".zig")) continue;
    const pattern = /std\.debug\.prnit/g;
    for (const match of file.text.matchAll(pattern)) {
      const before = file.text.slice(0, match.index + "std.debug.".length);
      const lines = before.split("\n");
      result.push({ file, offset: match.index + "std.debug.".length, line: lines.length, column: lines.at(-1).length + 1 });
    }
  }
  return result;
}
function renderProblems() {
  const issues = diagnostics();
  $("problem-count").textContent = issues.length;
  $("status-diagnostics").textContent = `⊗ ${issues.length}　△ 0`;
  $("problems-list").replaceChildren();
  for (const issue of issues) {
    const row = button("", "problem", () => openFile(issue.file.id, issue.line, issue.column, 5), `Go to ${issue.file.id}:${issue.line}:${issue.column}, unknown member prnit`);
    const detail = el("span", "problem-details");
    detail.append(el("span", "", "No member named ‘prnit’ in ‘std.debug’"), el("small", "", `${issue.file.id}:${issue.line}:${issue.column} · zig.fixture.001`));
    row.append(el("span", "", "⊗"), detail, el("span", "mini-badge", "fix available"));
    $("problems-list").append(row);
  }
  if (!issues.length) $("problems-list").append(el("div", "empty-state", "✓ No fixture diagnostics. This is not a full compile check."));
}
function codeAction() {
  const issue = diagnostics().find((item) => item.file.id === workspace.active);
  if (!issue) { toast("No fixture code action for this file."); return; }
  const version = issue.file.revision;
  openPicker("Code actions · LSP fixture", [{
    label: "Change ‘prnit’ to ‘print’", detail: "Quick fix · buffer only",
    action: () => {
      if (issue.file.revision !== version) { toast("Buffer changed. Request a fresh code action."); return; }
      changeText(issue.file, issue.file.text.slice(0, issue.offset) + "print" + issue.file.text.slice(issue.offset + 5));
      refreshAfterEdit({ loadEditor: true });
      openFile(issue.file.id, issue.line, issue.column, 5);
      toast("Applied fixture code action. The edit is unsaved and unstaged.");
    },
  }]);
}
function renderSearch() {
  const query = workspace.search.toLowerCase();
  $("search-results").replaceChildren();
  if (!query) { $("search-summary").textContent = "Search every file in this workspace."; return; }
  let count = 0;
  for (const file of workspace.files) {
    file.text.split("\n").forEach((line, lineIndex) => {
      const column = line.toLowerCase().indexOf(query);
      if (column < 0) return;
      count += 1;
      if (count > 100) return;
      const row = button("", "result-button", () => openFile(file.id, lineIndex + 1, column + 1, query.length));
      row.append(el("span", "result-path", `${file.id}:${lineIndex + 1}`), el("span", "result-line", line.trim() || "(empty line)"));
      $("search-results").append(row);
    });
  }
  $("search-summary").textContent = count ? `${count} matching lines${count > 100 ? " · first 100 shown" : ""}` : "No matches in this workspace.";
}
$("search-input").addEventListener("input", () => { workspace.search = $("search-input").value; renderSearch(); });
function addRoot() {
  if (workspace.roots.includes("notes-kit")) { toast("The sample root is already in this workspace."); return; }
  workspace.roots.push("notes-kit");
  workspace.files.push(makeFile("notes-kit", "README.md", "# Notes kit\n\nA third root, added without filesystem access.\n\nSearch, tabs, staging, and agents work with this sample too.\n"));
  renderTree();
  setView("explorer");
  toast("Added notes-kit to this workspace only. No folder picker or disk access was used.");
}
function switchWorkspace(next) {
  workspace = next;
  ui.diff = null;
  renderWorkspace();
  toast(`Switched to ${workspace.name}. Buffers, index, and threads are retained per workspace.`);
}
function workspacePicker() {
  openPicker("Workspaces", [
    ...workspaces.map((ws) => ({ label: `${ws === workspace ? "✓ " : ""}${ws.name}`, detail: `${ws.roots.length} roots · memory`, action: () => switchWorkspace(ws) })),
    { label: "Add sample root to current workspace", detail: "notes-kit", action: addRoot },
  ]);
}
function quickOpen() {
  openPicker("Quick open", workspace.files.map((file) => ({ label: file.path.split("/").at(-1), detail: file.id, action: () => openFile(file.id) })), "Search files across roots…");
}

// Line-based LCS gives independently stageable contiguous hunks. Large buffers
// fall back to a single prefix/suffix hunk, bounding work without truncating data.
function diffHunks(before, after) {
  if (before === after) return [];
  const a = before.split("\n");
  const b = after.split("\n");
  if (a.length * b.length > 250000) {
    let start = 0;
    while (start < a.length && start < b.length && a[start] === b[start]) start++;
    let endA = a.length, endB = b.length;
    while (endA > start && endB > start && a[endA - 1] === b[endB - 1]) { endA--; endB--; }
    return [{ oldStart: start, newStart: start, oldLines: a.slice(start, endA), newLines: b.slice(start, endB) }];
  }
  const matrix = Array.from({ length: a.length + 1 }, () => new Uint32Array(b.length + 1));
  for (let i = a.length - 1; i >= 0; i--) {
    for (let j = b.length - 1; j >= 0; j--) matrix[i][j] = a[i] === b[j] ? matrix[i + 1][j + 1] + 1 : Math.max(matrix[i + 1][j], matrix[i][j + 1]);
  }
  const hunks = [];
  let i = 0, j = 0, current = null;
  while (i < a.length || j < b.length) {
    if (i < a.length && j < b.length && a[i] === b[j]) {
      if (current) { hunks.push(current); current = null; }
      i++; j++;
      continue;
    }
    if (!current) current = { oldStart: i, newStart: j, oldLines: [], newLines: [] };
    if (j < b.length && (i === a.length || matrix[i][j + 1] > matrix[i + 1][j])) current.newLines.push(b[j++]);
    else current.oldLines.push(a[i++]);
  }
  if (current) hunks.push(current);
  return hunks;
}
function applyHunk(text, hunk, reverse = false) {
  const lines = text.split("\n");
  lines.splice(reverse ? hunk.newStart : hunk.oldStart, reverse ? hunk.newLines.length : hunk.oldLines.length, ...(reverse ? hunk.oldLines : hunk.newLines));
  return lines.join("\n");
}
function appendDiffLines(container, hunk) {
  for (const line of hunk.oldLines) container.append(el("div", "diff-line removed", `− ${line}`));
  for (const line of hunk.newLines) container.append(el("div", "diff-line added", `+ ${line}`));
}
function renderGit() {
  const staged = workspace.files.filter((file) => file.index !== file.head);
  const unstaged = workspace.files.filter((file) => file.text !== file.index);
  $("git-badge").textContent = new Set([...staged, ...unstaged]).size;
  $("git-branch-label").textContent = workspace.branch;
  $("branch-name").textContent = workspace.branch;
  $("commit-button").disabled = !staged.length || !workspace.commitDraft.trim();
  $("staged-summary").textContent = `${staged.length} staged file${staged.length === 1 ? "" : "s"} · ${unstaged.length} unstaged. Commit includes the index only.`;
  $("git-files").replaceChildren();
  for (const [name, files, isStaged] of [["Staged changes", staged, true], ["Working changes", unstaged, false]]) {
    $("git-files").append(el("h3", "git-group-title", `${name} · ${files.length}`));
    if (!files.length) $("git-files").append(el("div", "empty-state", isStaged ? "No staged changes." : "Working tree matches the index."));
    for (const file of files) {
      const row = el("div", "git-file");
      const open = button("", "git-file-open", () => openDiff(file.id, isStaged), `Review ${isStaged ? "staged" : "working"} diff for ${file.id}`);
      open.append(el("span", "", file.path.split("/").at(-1)), el("small", "", file.root));
      const stage = button(isStaged ? "−" : "+", "icon-button", () => {
        file.index = isStaged ? file.head : file.text;
        renderGit(); renderTree(); if (ui.diff) renderDiff();
        toast(`${isStaged ? "Unstaged" : "Staged"} ${file.id}. Buffer unchanged.`);
      }, `${isStaged ? "Unstage" : "Stage"} file ${file.id}`);
      row.append(open, stage);
      $("git-files").append(row);
    }
  }
  $("commit-history").replaceChildren(el("h3", "", "Simulated history"));
  if (!workspace.commits.length) $("commit-history").append(el("p", "hint", "Your staged snapshots will appear here."));
  for (const commit of workspace.commits.slice().reverse()) {
    const entry = el("div", "commit-entry");
    entry.append(el("code", "", commit.id), document.createTextNode(`  ${commit.message}`), el("p", "hint", `${commit.branch} · ${commit.files.length} file(s) · staged only`));
    $("commit-history").append(entry);
  }
}
function openDiff(id, staged) {
  openFile(id);
  ui.diff = { id, staged };
  $("code-view").hidden = true;
  $("diff-view").hidden = false;
  renderDiff();
  if (window.innerWidth <= 700) { toggleSidebar(false); }
  $("return-editor").focus();
}
function renderDiff() {
  if (!ui.diff) return;
  const { id, staged } = ui.diff;
  const file = fileById(id);
  const before = staged ? file.head : file.index;
  const after = staged ? file.index : file.text;
  const hunks = diffHunks(before, after);
  $("diff-title").textContent = file.id;
  $("diff-subtitle").textContent = staged ? "Staged · HEAD → index · included in the next simulated commit" : "Working · index → buffer · not included until staged";
  $("diff-content").replaceChildren();
  for (const [index, hunk] of hunks.entries()) {
    const section = el("section", "diff-hunk");
    const header = el("div", "hunk-header");
    const action = button(staged ? "Unstage hunk" : "Stage hunk", "quiet-button", () => {
      // The rendered hunk belongs to these exact snapshots, never newer edits.
      if ((staged ? file.head : file.index) !== before || (staged ? file.index : file.text) !== after) {
        renderDiff(); toast("Diff changed. Review the refreshed hunk before staging."); return;
      }
      file.index = applyHunk(file.index, hunk, staged);
      renderGit(); renderTree(); renderDiff();
      $("return-editor").focus();
      toast(`${staged ? "Unstaged" : "Staged"} hunk ${index + 1}; other hunks and the buffer are unchanged.`);
    }, `${staged ? "Unstage" : "Stage"} hunk ${index + 1} in ${id}`);
    header.append(el("span", "", `@@ −${hunk.oldStart + 1},${hunk.oldLines.length} +${hunk.newStart + 1},${hunk.newLines.length} @@`), action);
    const lines = el("div", "hunk-lines");
    appendDiffLines(lines, hunk);
    section.append(header, lines);
    $("diff-content").append(section);
  }
  if (!hunks.length) $("diff-content").append(el("div", "empty-state", staged ? "No staged hunks for this file. Your buffer has not been changed." : "No remaining working hunks for this file."));
}
function commitStaged() {
  const files = workspace.files.filter((file) => file.head !== file.index);
  const message = workspace.commitDraft.trim();
  if (!files.length || !message) { toast("Stage at least one hunk and enter a commit message first."); return; }
  const commit = {
    id: `sim-${String(workspace.commits.length + 1).padStart(3, "0")}`, message, branch: workspace.branch,
    files: files.map((file) => ({ id: file.id, before: file.head, after: file.index })),
  };
  // Deliberately never copy the working buffer into HEAD during commit.
  for (const file of files) file.head = file.index;
  workspace.commits.push(commit);
  workspace.commitDraft = "";
  $("commit-message").value = "";
  renderGit(); renderTree(); if (ui.diff) renderDiff();
  toast(`${commit.id}: committed ${files.length} staged file(s) only. Unstaged edits remain in your buffers.`);
}
$("commit-message").addEventListener("input", () => { workspace.commitDraft = $("commit-message").value; renderGit(); });
function branchPicker() {
  openPicker("Switch branch · simulation", workspace.branches.map((branch) => ({
    label: `${branch === workspace.branch ? "✓ " : ""}${branch}`, detail: "Label only · changes retained",
    action: () => {
      workspace.branch = branch;
      renderGit();
      toast(`Simulated branch: ${branch}. This changes the label only; no checkout occurs.`);
    },
  })));
}

function renderContext() {
  $("agent-context").textContent = activeFile().path.split("/").at(-1);
}
function addMessage(container, role, text) {
  const message = el("article", `message${role === "user" ? " user-message" : ""}`);
  const label = el("div", "message-label");
  label.append(el("span", "avatar", role === "user" ? "Y" : "✧"), document.createTextNode(role === "user" ? "You" : "Coral · fixture"));
  message.append(label, el("div", "message-body", text));
  container.append(message);
}
function taskCard(thread, task) {
  const card = el("section", "tool-card");
  const labels = { approval: "Approval required", working: "Reading memory fixture…", proposed: "Patch ready for review", applied: "Patch accepted", rejected: "Patch rejected", cancelled: "Request cancelled", denied: "Read denied", stale: "Patch blocked · buffer changed", answered: "Read complete · Ask profile" };
  const header = el("div", "tool-card-header");
  header.append(el("strong", "", labels[task.status]), el("span", "mini-badge", "simulated"));
  const body = el("div", "tool-card-body");
  body.append(el("div", "tool-path", `read_buffer → ${task.fileId}`));
  const descriptions = {
    approval: "Allow a read of this in-memory buffer? No shell, filesystem, provider, or other files are accessed.",
    working: "Preparing a deterministic response from the approved snapshot. You can cancel before it completes.",
    proposed: "Review this exact patch. Accept edits only this buffer; it does not save, stage, or commit.",
    applied: "Applied to the buffer. Review in Source Control and stage separately when ready.",
    rejected: "No changes were applied to the buffer or index.",
    cancelled: "Stopped locally. No proposed edit was applied.",
    denied: "The buffer was not read. No patch was generated.",
    stale: "The target buffer changed after the approved read. This patch cannot be applied. Send a new request for a fresh snapshot.",
    answered: task.answer || "The approved buffer was inspected. Ask never proposes edits.",
  };
  body.append(el("p", "", descriptions[task.status]), el("p", "hint", `${task.model} · ${task.profile === "ask" ? "Ask" : "Edit"} profile`));
  card.append(header, body);
  if (["proposed", "applied", "rejected", "stale"].includes(task.status) && task.before !== undefined && task.after !== undefined) {
    const preview = el("div", "patch-preview");
    for (const hunk of diffHunks(task.before, task.after)) appendDiffLines(preview, hunk);
    card.append(preview);
  }
  const actions = el("div", "tool-actions");
  if (task.status === "approval") {
    actions.append(button("Allow read", "primary", () => approveTask(thread, task)), button("Deny", "quiet-button", () => finishTask(thread, task, "denied")));
  }
  if (task.status === "proposed") {
    actions.append(button("Accept patch", "primary", () => acceptTask(thread, task)), button("Reject", "quiet-button", () => finishTask(thread, task, "rejected")));
  }
  if (["approval", "working"].includes(task.status)) actions.append(button("Cancel request", "quiet-button", () => finishTask(thread, task, "cancelled")));
  if (task.status === "stale") actions.append(button("Prepare new request", "quiet-button", () => {
    thread.draft = task.prompt;
    renderAgent(); $("agent-prompt").focus();
  }));
  if (actions.childElementCount) card.append(actions);
  return card;
}
function renderAgent() {
  const thread = activeThread();
  $("thread-title").textContent = thread.title;
  $("agent-prompt").value = thread.draft;
  $("agent-model").value = thread.model;
  $("agent-profile").value = thread.profile;
  $("agent-send").disabled = busy(thread.task) || !thread.draft.trim();
  $("agent-model").disabled = busy(thread.task);
  $("agent-profile").disabled = busy(thread.task);
  $("agent-messages").replaceChildren();
  for (const message of thread.messages) {
    if (message.task) $("agent-messages").append(taskCard(thread, message.task));
    else addMessage($("agent-messages"), message.role, message.text);
  }
  renderContext();
  $("agent-messages").scrollTop = $("agent-messages").scrollHeight;
}
function submitAgent(event) {
  event.preventDefault();
  const thread = activeThread();
  const prompt = thread.draft.trim();
  if (!prompt || busy(thread.task)) return;
  if (thread.title === "A careful first pass") thread.title = prompt.slice(0, 42);
  const task = { status: "approval", fileId: workspace.active, workspace, prompt, model: thread.model, profile: thread.profile, timer: null };
  thread.messages.push({ role: "user", text: prompt }, { task });
  thread.task = task;
  thread.draft = "";
  renderAgent();
  $("agent-messages").querySelector(".tool-card:last-child .primary")?.focus();
}
function approveTask(thread, task) {
  if (task.status !== "approval") return;
  const file = fileById(task.fileId, task.workspace);
  task.before = file.text;
  task.revision = file.revision;
  task.status = "working";
  renderAgent();
  $("agent-messages").querySelector(".tool-card:last-child button")?.focus();
  task.timer = setTimeout(() => {
    if (task.status !== "working") return;
    if (task.profile === "ask") {
      task.answer = `Inspected ${task.fileId}: ${task.before.split("\n").length} lines. ${task.before.includes("std.debug.prnit") ? "The fixture typo is present; use the code action or Edit profile to fix it." : "No known fixture typo was found."} This is a canned report, not general code analysis.`;
      task.status = "answered";
    } else {
      if (task.before.includes("std.debug.prnit")) task.after = task.before.replace("std.debug.prnit", "std.debug.print");
      else {
        const note = task.fileId.endsWith(".zig") ? "// Agent fixture: keep workspace changes explicit.\n" : "> Agent fixture: keep workspace changes explicit.\n";
        task.after = task.before + (task.before.endsWith("\n") ? "" : "\n") + note;
      }
      task.status = file.revision === task.revision ? "proposed" : "stale";
    }
    if (workspace === task.workspace && activeThread() === thread) {
      const focusWasInCard = document.activeElement.closest?.(".tool-card");
      renderAgent();
      if (focusWasInCard) ($("agent-messages").querySelector(".tool-card:last-child button") || $("agent-prompt")).focus();
    }
  }, 800);
}
function finishTask(thread, task, status) {
  if (!busy(task)) return;
  clearTimeout(task.timer);
  task.status = status;
  renderAgent();
  $("agent-prompt").focus();
}
function acceptTask(thread, task) {
  if (task.status !== "proposed") return;
  const file = fileById(task.fileId, task.workspace);
  if (file.revision !== task.revision || file.text !== task.before) {
    task.status = "stale";
    renderAgent();
    toast("Patch blocked: the buffer changed after the approved read.");
    return;
  }
  if (task.after.length > 30000) { toast("Patch exceeds the 30,000-character prototype buffer limit. Reject it or shorten the buffer first."); return; }
  changeText(file, task.after);
  task.status = "applied";
  refreshAfterEdit({ loadEditor: true });
  renderAgent();
  $("agent-prompt").focus();
  toast("Accepted into the buffer only. No save, staging, or commit was performed.");
}
function markStaleTasks() {
  let changed = false;
  for (const thread of workspace.threads) {
    const task = thread.task;
    if (task?.status === "proposed" && fileById(task.fileId).revision !== task.revision) {
      task.status = "stale";
      if (thread === activeThread()) changed = true;
    }
  }
  if (changed) renderAgent();
}
function newThread() {
  const thread = makeThread();
  workspace.threads.push(thread);
  workspace.threadId = thread.id;
  renderAgent(); toggleAgent(true);
}
function threadPicker() {
  openPicker("Agent threads · current workspace", workspace.threads.slice().reverse().map((thread) => ({
    label: thread.title,
    detail: `${thread.id === workspace.threadId ? "Current · " : ""}${thread.task?.status || "New thread"}`,
    action: () => { workspace.threadId = thread.id; renderAgent(); toggleAgent(true); },
  })));
}
$("agent-form").addEventListener("submit", submitAgent);
$("agent-prompt").addEventListener("input", () => {
  activeThread().draft = $("agent-prompt").value;
  $("agent-send").disabled = busy(activeThread().task) || !activeThread().draft.trim();
});
$("agent-prompt").addEventListener("keydown", (event) => {
  if ((event.ctrlKey || event.metaKey) && event.key === "Enter") submitAgent(event);
});
$("agent-model").addEventListener("change", () => { activeThread().model = $("agent-model").value; });
$("agent-profile").addEventListener("change", () => { activeThread().profile = $("agent-profile").value; });

function renderTerminal() {
  $("terminal-output").textContent = workspace.terminal.join("\n");
  $("terminal-output").scrollTop = $("terminal-output").scrollHeight;
}
function runTerminal(command) {
  const value = command.trim();
  if (!value) return;
  if (value === "clear") workspace.terminal = [];
  else {
    workspace.terminal.push(`coral › ${value}`);
    if (value === "help") workspace.terminal.push("SIMULATION ONLY. Commands: help, clear, zig build, git status. Nothing is executed.");
    else if (value === "zig build") {
      const count = diagnostics().length;
      workspace.terminal.push(count ? `Fixture check: ${count} known typo(s) found. See Problems. No compiler was run.` : "Fixture check: no known typos. This does NOT establish that the code compiles. No compiler was run.");
    } else if (value === "git status") {
      workspace.terminal.push(`Simulated branch: ${workspace.branch}`);
      for (const file of workspace.files) {
        const staged = file.index !== file.head;
        const unstaged = file.text !== file.index;
        if (staged || unstaged) workspace.terminal.push(`${staged ? "M" : " "}${unstaged ? "M" : " "} ${file.id}  (index / buffer)`);
      }
      if (workspace.files.every((file) => file.head === file.index && file.index === file.text)) workspace.terminal.push("Fixture working tree clean.");
    } else workspace.terminal.push("Unsupported command in this simulation. Type help. No shell or program was started.");
  }
  workspace.terminal = workspace.terminal.slice(-200);
  renderTerminal();
}
$("terminal-form").addEventListener("submit", (event) => {
  event.preventDefault(); runTerminal($("terminal-input").value); $("terminal-input").value = "";
});
function runChecks() { setPanel("terminal"); runTerminal("zig build"); $("terminal-input").focus(); }
function help() {
  notice("Coral workbench · offline prototype", "Everything is simulated and resets on reload. No files, shell commands, providers, or credentials are accessed.\n\nCtrl/⌘+P — Quick open\nCtrl/⌘+Shift+P or Ctrl/⌘+K — Commands\nCtrl/⌘+Shift+F — Workspace search\nCtrl/⌘+B / J — Sidebar / bottom panel\nCtrl/⌘+S — Save in memory\nCtrl/⌘+. — Fixture code action\nCtrl/⌘+Enter — Send agent prompt\nEscape — Close dialogs or mobile drawers\n\nTry staging one main.zig hunk, then commit: remaining hunks stay unstaged. Ask the agent to fix the diagnostic; approve its read, then edit the file before accepting to see the stale-patch guard.\n\nBranch switching changes a label only. Model selection is illustrative; Ask returns a canned report and Edit proposes a canned patch. Browser-reserved shortcuts may require the visible buttons.");
}
function commands() {
  openPicker("Command palette", [
    { label: "Go to file…", detail: "Ctrl/⌘ P", action: quickOpen },
    { label: "Workspace: switch…", detail: "Memory fixtures", action: workspacePicker },
    { label: "Workspace: add sample root", detail: "notes-kit", action: addRoot },
    { label: "View: Explorer", detail: "Sidebar", action: () => setView("explorer") },
    { label: "Search: find in workspace", detail: "Ctrl/⌘ Shift F", action: () => setView("search") },
    { label: "Git: source control", detail: "Review and stage", action: () => setView("git") },
    { label: "Git: switch simulated branch…", detail: "Label only", action: branchPicker },
    { label: "File: save preview", detail: "Memory only", action: savePreview },
    { label: "LSP: code actions…", detail: "Fixture fix", action: codeAction },
    { label: "Agent: new thread", detail: "Offline fixture", action: newThread },
    { label: "Agent: thread history…", detail: "Current workspace", action: threadPicker },
    { label: "View: toggle agent dock", action: () => toggleAgent() },
    { label: "View: toggle sidebar", detail: "Ctrl/⌘ B", action: () => toggleSidebar() },
    { label: "View: toggle bottom panel", detail: "Ctrl/⌘ J", action: () => { ui.panel = !ui.panel; applyLayout(); } },
    { label: "Appearance: toggle theme", detail: "Dark / light", action: toggleTheme },
    { label: "Run: fixture checks", detail: "No compiler", action: runChecks },
    { label: "Help: simulation boundaries", action: help },
  ], "Type a command…");
}
function renderWorkspace() {
  $("workspace-name").textContent = workspace.name;
  $("search-input").value = workspace.search;
  $("commit-message").value = workspace.commitDraft;
  renderTree(); renderTabs(); renderEditor(); renderProblems(); renderSearch(); renderGit(); renderAgent(); renderTerminal(); applyLayout();
}
const actions = {
  "workspace-button": workspacePicker, "command-button": commands, "quick-open": quickOpen,
  "sidebar-toggle": () => toggleSidebar(), "sidebar-close": () => { toggleSidebar(false); $("sidebar-toggle").focus(); },
  "agent-toggle": () => toggleAgent(), "agent-close": () => { toggleAgent(false); $("agent-toggle").focus(); },
  "panel-toggle": () => { ui.panel = !ui.panel; applyLayout(); },
  "panel-close": () => { ui.panel = false; applyLayout(); $("panel-toggle").focus(); },
  "theme-toggle": toggleTheme, "help-button": help, "run-button": runChecks,
  "add-root": addRoot, "save-button": savePreview, "code-action": codeAction,
  "problems-tab": () => setPanel("problems"), "terminal-tab": () => setPanel("terminal"),
  "status-problems": () => setPanel("problems"), "status-agent": () => toggleAgent(true),
  "branch-button": branchPicker, "commit-button": commitStaged,
  "return-editor": () => openFile(ui.diff?.id || workspace.active),
  "new-thread": newThread, "thread-history": threadPicker,
  "lsp-status": () => notice("Language server · fixture", "No language server is running. The prototype scans .zig buffers for std.debug.prnit, reports its location, and offers a replacement with std.debug.print.\n\nDiagnostics update as you type. Other syntax and type errors are not detected. Syntax coloring is a small regular-expression fixture, not a parser."),
};
for (const [id, action] of Object.entries(actions)) $(id).addEventListener("click", action);
for (const item of document.querySelectorAll("[data-view]")) item.addEventListener("click", () => setView(item.dataset.view));
for (const name of ["problems", "terminal"]) {
  $(`${name}-tab`).addEventListener("keydown", (event) => {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    const target = event.key === "Home" ? "problems" : event.key === "End" ? "terminal" : name === "problems" ? "terminal" : "problems";
    setPanel(target); $(`${target}-tab`).focus();
  });
}
document.addEventListener("keydown", (event) => {
  if (document.querySelector("dialog[open]") || event.isComposing) return;
  if (event.key === "Escape") {
    if (window.innerWidth <= 1100 && ui.agent) { toggleAgent(false); $("agent-toggle").focus(); }
    else if (window.innerWidth <= 700 && ui.sidebar) { toggleSidebar(false); $("sidebar-toggle").focus(); }
    return;
  }
  if (!(event.ctrlKey || event.metaKey) || event.altKey) return;
  const key = event.key.toLowerCase();
  let action;
  if (key === "p") action = event.shiftKey ? commands : quickOpen;
  else if (key === "k") action = commands;
  else if (key === "f" && event.shiftKey) action = () => setView("search");
  else if (key === "b") action = () => toggleSidebar();
  else if (key === "j") action = () => { ui.panel = !ui.panel; applyLayout(); };
  else if (key === "s") action = savePreview;
  else if (key === ".") action = codeAction;
  if (action) { event.preventDefault(); action(); }
});
let lastWidth = window.innerWidth;
window.addEventListener("resize", () => {
  const width = window.innerWidth;
  if (width <= 1100 && lastWidth > 1100) ui.agent = false;
  if (width <= 700 && lastWidth > 700) ui.sidebar = false;
  lastWidth = width;
  applyLayout();
});
renderWorkspace();
