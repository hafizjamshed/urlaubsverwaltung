# Fork Upgrade Guide – Urlaubsverwaltung + own features

How to move this fork to a newer upstream release **without losing our own features**
(currently: OIDC role sync), then build and deploy a new image.

Last done: **6.4.0 → 6.14.0** on 2026-10-01.

---

## 0. The big picture

```
upstream (urlaubsverwaltung/urlaubsverwaltung)     ← new features come from here
   tag urlaubsverwaltung-6.14.0  ─┐
                                  └─ our branch oidc-role-sync-v6.14.0
                                        + feat: OIDC role sync      (our commit)
                                        + Dockerfile                (our commit)
origin (hafizjamshed/urlaubsverwaltung)            ← we push our branch here
Harbor  harbor.stg-internal.granvalora.de/granvalora/urlaubsverwaltung:<branch>
```

Rules:

- **Always build on a release tag** (`urlaubsverwaltung-X.Y.Z`), never on `upstream/main`.
  `main` is daily development and not stable.
- **One branch per upstream version**: `oidc-role-sync-v<version>`.
  The old branch and old image stay untouched → easy rollback.
- **Our changes stay small commits on top of the tag.** Upgrading = re-applying
  those commits on the new tag (`git cherry-pick`).

Our own commits (on top of 6.14.0):

| Commit | What | Files |
|---|---|---|
| `feat: synchronize OIDC roles to database permissions on login` | Keycloak roles are written to the DB on every login | `security/oidc/PersonOnSuccessfullyOidcLoginEventHandler.java`, `security/oidc/OidcSecurityConfiguration.java`, the handler's unit test |
| `docker file added` | Build the image | `Dockerfile` |

---

## 1. Before you start – checklist

- [ ] Working tree is clean: `git status` → `nothing to commit, working tree clean`
- [ ] You know your current version: `git describe --tags --abbrev=0` (e.g. `urlaubsverwaltung-6.14.0`)
- [ ] Optional, once: better conflict view
      `git config --global merge.conflictstyle zdiff3`
      (shows the original code between the two sides of a conflict)

---

## 2. Fetch upstream and see what is new

```bash
git fetch upstream --tags
git tag -l 'urlaubsverwaltung-*' --sort=-v:refname | head -5      # newest releases
```

Set two variables for the rest of the guide (Git Bash / WSL):

```bash
OLD=urlaubsverwaltung-6.14.0        # version we are on now
NEW=urlaubsverwaltung-6.15.0        # version we want
```

Read what changed:

```bash
# number of upstream commits
git log --oneline $OLD..$NEW | wc -l

# list of changes (q to quit)
git log --oneline --no-merges $OLD..$NEW

# OUR commits on the current branch (these must be carried over)
git log --oneline $OLD..HEAD

# did upstream touch the files WE changed?  → predicts conflicts
git diff --stat $OLD $NEW -- src/main/java/org/synyx/urlaubsverwaltung/security/oidc/ \
                             src/main/java/org/synyx/urlaubsverwaltung/person/ Dockerfile
```

Also read the release notes for every version in between:
https://github.com/urlaubsverwaltung/urlaubsverwaltung/releases

Look especially for:

- **Breaking changes / removed roles / renamed settings** (e.g. 6.14.0 removed the
  `INACTIVE` role: a person without the `USER` role is now inactive).
- **Java version** – check `.tool-versions`. If it changes, update the Dockerfile
  (`maven:3.9-eclipse-temurin-XX` and `eclipse-temurin:XX-jre`).
- **New required config / environment variables.**

---

## 3. Create the new branch from the new tag

```bash
git checkout -b oidc-role-sync-v6.15.0 $NEW
```

---

## 4. Re-apply our commits

Take the commit ids from `git log --oneline $OLD..oidc-role-sync-v6.14.0`,
**oldest first**:

```bash
git cherry-pick <feature-commit> <dockerfile-commit>
```

### No conflict?
Go to step 5.

### Conflict?
```
CONFLICT (content): Merge conflict in .../PersonOnSuccessfullyOidcLoginEventHandler.java
```

1. `git status` shows the file under **both modified**. Files listed under
   *Changes to be committed* merged fine – leave them alone.
2. Open the file. Every conflict looks like this:
   ```
   <<<<<<< HEAD         ← upstream's new version (the tag you are on)
   ...
   ||||||| parent       ← original code (only with zdiff3)
   ...
   =======
   ...                  ← our commit
   >>>>>>> abc1234 (feat: ...)
   ```
3. Decide per block:
   - Only imports differ → keep **both**.
   - Real code → **do not click "Accept Both"** blindly. Write the result by hand:
     keep **upstream's new style / API** and put **our logic** into it.
     (Accept Both on the 6.14.0 upgrade produced duplicated code and a broken `if/else`.)
4. Remove all marker lines, then check:
   ```bash
   grep -rn -E '^(<<<<<<<|=======|>>>>>>>|\|\|\|\|\|\|\|)' src/
   ```
   must print nothing.
5. **Look for hidden breakage.** Git only shows *text* conflicts. Code that merged
   "cleanly" can still call methods upstream deleted. Search our code for anything
   upstream removed or renamed, e.g.:
   ```bash
   git diff $OLD $NEW -- src/main/java/org/synyx/urlaubsverwaltung/person/Role.java
   git diff $OLD $NEW -- src/main/java/org/synyx/urlaubsverwaltung/person/PersonService.java
   ```
   The compile in step 5 catches the rest.
6. Do **not** continue yet – first build and test (step 5).

### Stuck? Cancel and start over
```bash
git cherry-pick --abort
# if it complains "not uptodate. Cannot merge":
git update-index --refresh && git cherry-pick --abort
# or:  git reset --merge
git status          # leftovers? → git restore <file>
```
Nothing is lost: our commits still exist on the old branch and on GitHub.

### What happened in 6.4.0 → 6.14.0 (for reference)

| Upstream change | What we had to do |
|---|---|
| `person.setFirstName(..)` + `personService.update(person)` replaced by `personService.update(id, PersonUpdate.ofPersonalData(..))` | Use `PersonUpdate...withPermissions(getRoles(oidcUser))` |
| `Role.validRole(..)` deleted | Filter with `Arrays.stream(Role.values()).map(Role::name)` |
| `appointAsOfficeUserIfNoOfficeUserPresent(Person)` → takes `PersonId` | `createdPerson.getIdAsPersonId()` |
| Handler constructor got a 2nd parameter (ours) | Unit test: `new PersonOnSuccessfullyOidcLoginEventHandler(personService, new RolesFromClaimMappersProperties())` |

---

## 5. Compile and test (before finishing the cherry-pick)

Java/Maven are not installed locally – run Maven in Docker (from **WSL**, in the project folder):

```bash
docker run --rm -v "$PWD":/src -v uv-m2:/root/.m2 -w /src maven:3.9-eclipse-temurin-25 \
  mvn -B -Dskip.npm -Dskip.installnodenpm \
      -Dtest='PersonOnSuccessfullyOidcLoginEventHandlerTest' \
      -Dsurefire.failIfNoSpecifiedTests=false test
```

- Expect `BUILD SUCCESS`. (Change `temurin-25` if the Java version changed.)
- `ERROR ... Can not retrieve the given name` log lines are normal – those tests check missing names.
- The text summary may say `Tests run: 0` (nested test classes); the real count is in
  `target/surefire-reports/*.xml` (`tests="10" failures="0"`).

Then finish:

```bash
git add <the files you fixed>
git cherry-pick --continue
git log --oneline -4          # our commits on top of "New Release Version ..."
```

---

## 6. Push the branch to GitHub

```bash
git push -u origin oidc-role-sync-v6.15.0
```

`user.name` / `user.email` only label commits. **Who may push is decided by the GitHub
login** stored in Windows Credential Manager.

`Permission to hafizjamshed/urlaubsverwaltung.git denied to zohaib-jamshed24` (403) means
you are logged in as the wrong account. Fix either:

- add `zohaib-jamshed24` as collaborator:
  https://github.com/hafizjamshed/urlaubsverwaltung/settings/access, **or**
- log out and push as `hafizjamshed`:
  `git credential-manager github logout zohaib-jamshed24`
  (or delete `git:https://github.com` in Windows *Credential Manager → Windows Credentials*).

---

## 7. Build and push the image

From **WSL** (Docker there is logged in to Harbor):

```bash
cd /mnt/c/Users/hafiz.E16GEN2/Documents/projects/projects/urlaubsverwaltung-fork/urlaubsverwaltung

docker build -t harbor.stg-internal.granvalora.de/granvalora/urlaubsverwaltung:oidc-role-sync-v6.15.0 .
docker images | grep oidc-role-sync-v6.15.0
docker push  harbor.stg-internal.granvalora.de/granvalora/urlaubsverwaltung:oidc-role-sync-v6.15.0
```

- First build: ~10–15 min (Maven + npm downloads, frontend build).
- `unauthorized` on push → `docker login harbor.stg-internal.granvalora.de`.

The Dockerfile (committed in the repo; it used to live only in `/tmp` and was nearly lost):

```dockerfile
FROM maven:3.9-eclipse-temurin-25 as builder
WORKDIR /workspace
COPY . /workspace
RUN mvn clean package -DskipTests

FROM eclipse-temurin:25-jre
WORKDIR /app
COPY --from=builder /workspace/target/urlaubsverwaltung-*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```

---

## 8. Before deploying – IMPORTANT

1. **Back up the database.** Urlaubsverwaltung runs **Liquibase** on startup and
   upgrades the DB schema automatically (`src/main/resources/dbchangelogs/`).
   After that, the **old image may no longer start** against the upgraded DB.
   Without a backup there is no real rollback.
2. **Check Keycloak roles** for anything the release notes changed.
   Since 6.14.0 every user needs `urlaubsverwaltung_user`, otherwise they are inactive.
3. Check new/renamed config in the release notes against
   `env/dev/values/urlaubsverwaltung.yaml` (kubernetes-applications repo).

---

## 9. Deploy and verify

Cluster: dev, namespace `urlaubsverwaltung`, deployment `dev-urlaubsverwaltung`.
Deployed by **ArgoCD** (app `dev-urlaubsverwaltung`) – don't `helm upgrade` by hand,
ArgoCD would undo it.

1. In the GitLab repo `granvalora/kubernetes/kubernetes-applications`, branch `ovh-dev`,
   edit `env/dev/values/urlaubsverwaltung.yaml`: change the image tag from
   `oidc-role-sync-v6.14.0` to `oidc-role-sync-v6.15.0`. Commit + push → ArgoCD rolls it out.
2. Watch startup (Liquibase migration runs here):
   ```bash
   kubectl -n urlaubsverwaltung logs deploy/dev-urlaubsverwaltung -f
   ```
3. Test:
   - [ ] Login via Keycloak works
   - [ ] A user with `urlaubsverwaltung_office` / `_boss` sees the matching menus
   - [ ] Change a role in Keycloak → log out/in → permission changes in the app
   - [ ] Version shown in the app footer is the new one

**Rollback:** set the old tag again **and** restore the DB backup from step 8.

---

## Quick reference

```bash
git fetch upstream --tags
git tag -l 'urlaubsverwaltung-*' --sort=-v:refname | head -5
git log --oneline $OLD..HEAD                              # our commits
git checkout -b oidc-role-sync-v<NEW> urlaubsverwaltung-<NEW>
git cherry-pick <our commits, oldest first>
#   conflict → fix → grep for markers → test (step 5) → git add → git cherry-pick --continue
git push -u origin oidc-role-sync-v<NEW>
docker build -t harbor.stg-internal.granvalora.de/granvalora/urlaubsverwaltung:oidc-role-sync-v<NEW> .
docker push  harbor.stg-internal.granvalora.de/granvalora/urlaubsverwaltung:oidc-role-sync-v<NEW>
# DB backup → change tag in kubernetes-applications (ovh-dev) → ArgoCD syncs → check logs → test logins/roles
```
