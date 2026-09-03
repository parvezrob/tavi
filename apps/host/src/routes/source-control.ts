import path from "node:path";
import { resolveWithinRoots } from "../files.js";
import { invalidateRepos, listReposCached } from "../git.js";
import { forgetPullRequest } from "../pull-request-cache.js";
import { git } from "../git-exec.js";
import { bodyRecord, readJsonBody, type Route, sendJson, sendPathFailure } from "../http.js";
import { createPullRequest, linkPullRequest, listIssues, pullRequestStatus } from "../pull-requests.js";
import { writeCommitMessage } from "../commit-message.js";
import { pullBase, pushBranch, worktreeLog } from "../commits.js";
import { currentBranch } from "../git-refs.js";
import { commitStaged, stageFiles, worktreeStatus } from "../source-control.js";
import { previewRemoval } from "../removal-preview.js";
import { removeWorktree } from "../removal.js";
import { createWorktree } from "../worktrees.js";

export const sourceControlRoutes: Route = async (url, request, response, context) => {
  const { config, herdr, projects, pullRequests, gh } = context;
  const ghDeps = gh ? { gh } : {};

  // Read-only worktree and branch visibility (#59a): every git repository
  // reachable from the configured roots, with every worktree git itself
  // knows about — "where is my work happening" in one call.
  if (url.pathname === "/api/repos" && request.method === "GET") {
    const answer = await listReposCached(
      config.roots,
      pullRequests ? { pullRequests } : {},
      url.searchParams.get("fresh") === "1",
    );
    sendJson(response, 200, {
      repos: answer.repos,
      truncated: answer.truncated,
      ...(answer.error ? { error: answer.error } : {}),
    });
    return true;
  }

  // Create a worktree (#75, #73 part 2): the third answer to "where" in
  // the New Agent sheet. The folder is judged against the roots before git
  // hears of it; outside them the phone must confirm, as for #24.
  if (url.pathname === "/api/worktrees" && request.method === "POST") {
    const body = await readJsonBody(request);
    const record = bodyRecord(body);
    if (typeof record.repo !== "string" || typeof record.branch !== "string") {
      sendJson(response, 400, { error: "repo and branch are required." });
      return true;
    }
    const result = await createWorktree(
      { repo: record.repo, branch: record.branch, base: typeof record.base === "string" ? record.base : undefined },
      config.roots,
      { allowOutsideRoots: record.allowOutsideRoots === true },
    );
    if (!result.ok) return sendPathFailure(response, result);
    projects.remember(result.worktree.path);
    invalidateRepos();
    sendJson(response, 201, { worktree: result.worktree });
    return true;
  }

  // Source Control — Changes (#77, #73 part 3): one worktree's status,
  // staging, and commits. `path` is the worktree, realpath'd then checked
  // against the roots like every file route; the writes are fixed argv.
  if (url.pathname === "/api/worktrees/status" && request.method === "GET") {
    const target = await resolveWithinRoots(url.searchParams.get("path") ?? "", "/", config.roots);
    if (!target.ok) return sendPathFailure(response, target);
    const result = await worktreeStatus(target.path);
    if (!result.ok) {
      sendJson(response, result.status, {
        error: result.error,
        ...(result.notRepository ? { notRepository: true } : {}),
      });
      return true;
    }
    sendJson(response, 200, result.status);
    return true;
  }

  // Remove a worktree (#81, #73 part 6): a preview that names what would be
  // lost, then a removal that must repeat those counts back. The agents
  // herdr runs inside it are closed first.
  const removalDeps = {
    agents: async () => {
      if (!herdr) return [];
      const result = await herdr.listAgents();
      return result.available ? result.agents : [];
    },
    closeTab: async (tabId: string) => {
      if (!herdr) return false;
      return (await herdr.closeTab(tabId)).closed;
    },
  };
  if (url.pathname === "/api/worktrees/removal" && request.method === "GET") {
    const target = await resolveWithinRoots(url.searchParams.get("path") ?? "", "/", config.roots);
    if (!target.ok) return sendPathFailure(response, target);
    const result = await previewRemoval(target.path, removalDeps);
    sendJson(response, result.ok ? 200 : result.status, result.ok ? result.preview : { error: result.error });
    return true;
  }
  if (url.pathname === "/api/worktrees" && request.method === "DELETE") {
    const body = await readJsonBody(request);
    const record = bodyRecord(body);
    const target = await resolveWithinRoots(typeof record.path === "string" ? record.path : "", "/", config.roots);
    if (!target.ok) return sendPathFailure(response, target);
    const confirm =
      typeof record.confirm === "object" && record.confirm !== null
        ? (record.confirm as Record<string, unknown>)
        : null;
    if (!confirm || typeof confirm.uncommitted !== "number" || typeof confirm.unpushed !== "number") {
      sendJson(response, 400, { error: "confirm must carry the uncommitted and unpushed counts you were shown." });
      return true;
    }
    const result = await removeWorktree(
      target.path,
      {
        confirm: { uncommitted: confirm.uncommitted, unpushed: confirm.unpushed },
        pushFirst: record.pushFirst === true,
        deleteBranch: typeof record.deleteBranch === "boolean" ? record.deleteBranch : undefined,
        unlock: record.unlock === true,
      },
      removalDeps,
    );
    if (!result.ok) {
      sendJson(response, result.status, {
        error: result.error,
        ...(result.preview ? { preview: result.preview } : {}),
      });
      return true;
    }
    projects.forget(result.removed.path);
    invalidateRepos();
    sendJson(response, 200, { removed: result.removed });
    return true;
  }

  // Open issues for naming a branch (#79): the create sheet's "From a
  // GitHub issue". `repo` is any folder inside the repository.
  if (url.pathname === "/api/repos/issues" && request.method === "GET") {
    const target = await resolveWithinRoots(url.searchParams.get("repo") ?? "", "/", config.roots);
    if (!target.ok) return sendPathFailure(response, target);
    const result = await listIssues(target.path, ghDeps);
    sendJson(response, 200, { issues: result.issues, gh: result.gh });
    return true;
  }

  // Source Control — Pull request (#79, #73 part 5): read, create (pushing
  // first), or link the branch's pull request through the person's own gh.
  if (url.pathname === "/api/worktrees/pull-request" && request.method === "GET") {
    const target = await resolveWithinRoots(url.searchParams.get("path") ?? "", "/", config.roots);
    if (!target.ok) return sendPathFailure(response, target);
    const result = await pullRequestStatus(target.path, ghDeps);
    sendJson(response, result.ok ? 200 : result.status, result.ok ? result.status : { error: result.error });
    return true;
  }
  const pullRequestWrite = url.pathname.match(/^\/api\/worktrees\/pull-request(\/link)?$/);
  if (pullRequestWrite && request.method === "POST") {
    const body = await readJsonBody(request);
    const record = bodyRecord(body);
    const target = await resolveWithinRoots(typeof record.path === "string" ? record.path : "", "/", config.roots);
    if (!target.ok) return sendPathFailure(response, target);
    if (pullRequestWrite[1]) {
      const result = await linkPullRequest(target.path, { number: record.number, url: record.url }, ghDeps);
      if (result.ok) await forgetPullRequestBadge(target.path);
      sendJson(
        response,
        result.ok ? 200 : result.status,
        result.ok ? { pullRequest: result.pullRequest } : { error: result.error },
      );
      return true;
    }
    const result = await createPullRequest(
      target.path,
      {
        title: typeof record.title === "string" ? record.title : undefined,
        body: typeof record.body === "string" ? record.body : undefined,
        draft: record.draft === true,
      },
      ghDeps,
    );
    if (result.ok) await forgetPullRequestBadge(target.path);
    sendJson(
      response,
      result.ok ? 201 : result.status,
      result.ok ? { pullRequest: result.pullRequest, pushed: result.pushed } : { error: result.error },
    );
    return true;
  }

  // Source Control — Commits (#78, #73 part 4): the branch's commits over
  // and under its base, Push, and Pull main in.
  if (url.pathname === "/api/worktrees/log" && request.method === "GET") {
    const target = await resolveWithinRoots(url.searchParams.get("path") ?? "", "/", config.roots);
    if (!target.ok) return sendPathFailure(response, target);
    const result = await worktreeLog(target.path);
    sendJson(response, result.ok ? 200 : result.status, result.ok ? result.log : { error: result.error });
    return true;
  }

  const sourceControlWrite = url.pathname.match(
    /^\/api\/worktrees\/(stage|unstage|commit|commit-message|push|pull-base)$/,
  );
  if (sourceControlWrite && request.method === "POST") {
    const action = sourceControlWrite[1] as "stage" | "unstage" | "commit" | "commit-message" | "push" | "pull-base";
    const body = await readJsonBody(request);
    const record = bodyRecord(body);
    const target = await resolveWithinRoots(typeof record.path === "string" ? record.path : "", "/", config.roots);
    if (!target.ok) return sendPathFailure(response, target);
    if (action === "stage" || action === "unstage") {
      const files =
        record.files === "all"
          ? "all"
          : Array.isArray(record.files) && record.files.every((f) => typeof f === "string")
            ? (record.files as string[])
            : undefined;
      if (!files) {
        sendJson(response, 400, { error: 'files must be a list of repository paths, or "all".' });
        return true;
      }
      const result = await stageFiles(target.path, files, action);
      if (result.ok) invalidateRepos();
      sendJson(
        response,
        result.ok ? 200 : result.status,
        result.ok ? { staged: result.staged } : { error: result.error },
      );
      return true;
    }
    if (action === "commit") {
      const result = await commitStaged(target.path, typeof record.message === "string" ? record.message : "");
      if (result.ok) invalidateRepos();
      sendJson(
        response,
        result.ok ? 201 : result.status,
        result.ok ? { commit: result.commit } : { error: result.error },
      );
      return true;
    }
    if (action === "push") {
      const result = await pushBranch(target.path);
      if (result.ok) invalidateRepos();
      sendJson(
        response,
        result.ok ? 201 : result.status,
        result.ok ? { pushed: result.pushed, upstream: result.upstream } : { error: result.error },
      );
      return true;
    }
    if (action === "pull-base") {
      const result = await pullBase(target.path);
      if (result.ok) invalidateRepos();
      sendJson(
        response,
        result.ok ? (result.merged > 0 ? 201 : 200) : result.status,
        result.ok
          ? { merged: result.merged, fastForward: result.fastForward, sha: result.sha }
          : { error: result.error },
      );
      return true;
    }
    const result = await writeCommitMessage(target.path, { shell: config.shell });
    sendJson(
      response,
      result.ok ? 200 : result.status,
      result.ok ? { message: result.message } : { error: result.error },
    );
    return true;
  }
  return false;
};

// The home card's PR badge is cached per repo+branch (git.ts); a pull
// request this host just made or linked must show on the next poll.
async function forgetPullRequestBadge(worktreePath: string): Promise<void> {
  try {
    const branch = await currentBranch(worktreePath);
    const main = (await git(worktreePath, ["rev-parse", "--path-format=absolute", "--git-common-dir"])).stdout.trim();
    if (branch) forgetPullRequest(path.dirname(main), branch);
  } catch {
    // The badge simply refreshes on its own minute.
  }
}
