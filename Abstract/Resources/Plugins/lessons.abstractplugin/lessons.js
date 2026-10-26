"use strict";

// Lessons (ABS-102): a chat's own agent writes what the chat learned into
// the project's instructions or a skill. Nothing is written here and no
// model is called: the agent you already use makes the edit, and it waits
// in Review like any other change.
//
// `Lessons` is plain logic with no host calls, so tests run it as is; the
// screen is in app.js.
const Lessons = (() => {
  const targets = [
    {
      id: "instructions",
      title: "Project instructions",
      detail: "AGENTS.md or CLAUDE.md, which every chat in this project reads.",
    },
    {
      id: "newSkill",
      title: "A new skill",
      detail: "A skill of its own, for an agent to use when the work calls for it.",
    },
    {
      id: "existingSkill",
      title: "An existing skill",
      detail: "Added to a skill this project already has.",
    },
  ];

  const maxSkillName = 64;

  /** A skill's folder name: lowercase words joined by hyphens. */
  function skillName(raw) {
    return String(raw || "")
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, maxSkillName)
      .replace(/-+$/, "");
  }

  const what =
    "Look back over this chat and pick out what we learned that would help the next chat in this project: " +
    "commands that work, gotchas in the build or the tests, conventions I asked for or corrected, " +
    "and decisions we took and why. Leave out what's already written down, what only mattered for this one task, " +
    "and anything personal, like home directories, accounts or secrets.";

  const how =
    "Make it a minimal edit: add or adjust only those lessons, in the file's own style, and change nothing else " +
    "— no rewording, reformatting or other files. Don't commit: leave the edit uncommitted so I can review it. " +
    "If there's nothing worth saving, change nothing and say so. When you're done, list the lessons you wrote " +
    "in a few short lines.";

  // Skills outside the repository wouldn't show in Review, so the agent
  // is kept inside it.
  const skillFolder =
    "inside this repository, in the folder you read this project's skills from " +
    "(for example .claude/skills/<name>/SKILL.md for Claude, or .agents/skills/<name>/SKILL.md for Codex)";

  function where(target, skill) {
    const name = skillName(skill);
    switch (target) {
      case "instructions":
        return (
          "Write them into this project's instructions for agents: AGENTS.md or CLAUDE.md at the root of this " +
          "repository. Use the file the project already keeps its instructions in; if CLAUDE.md only points to " +
          "AGENTS.md (for example with @AGENTS.md), edit AGENTS.md. If neither exists, create AGENTS.md. " +
          "Put each lesson under the heading it fits, or add one short section."
        );
      case "newSkill":
        return (
          `Write them as a new skill ${name ? `named “${name}”` : "with a short, lowercase, hyphenated name that says what it's for"}, ` +
          `${skillFolder}. Start it with its name and a one-line description of when to use it, the way your skills ` +
          "begin, then the lessons as steps or rules. If a skill like it already exists, tell me instead of making " +
          "a second one, and change nothing."
        );
      case "existingSkill":
        return name
          ? `Add them to this project's skill “${name}”: its SKILL.md is ${skillFolder}. ` +
              "If there's no such skill inside this repository, tell me and change nothing."
          : `Add them to the skill in this project they fit best: its SKILL.md is ${skillFolder}. ` +
              "If no skill inside this repository fits, tell me and change nothing.";
      default:
        return null;
    }
  }

  /** The one message the chat's agent is sent, or null for an unknown target. */
  function request(target, skill) {
    const into = where(target, skill);
    if (!into) return null;
    return `${what}\n\n${into}\n\n${how}`;
  }

  /** The chat the menu item was chosen on, from the snapshot. */
  function chatOf(snapshot, chatId) {
    if (!chatId || !snapshot || !Array.isArray(snapshot.chats)) return null;
    return snapshot.chats.find((chat) => chat.id === chatId) || null;
  }

  /** Whether the target names a skill, so the screen asks for its name. */
  function takesSkillName(target) {
    return target === "newSkill" || target === "existingSkill";
  }

  return { targets, skillName, request, chatOf, takesSkillName };
})();

if (typeof window !== "undefined") window.Lessons = Lessons;
