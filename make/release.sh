#!/usr/bin/env bash
set -euo pipefail

RELEASE_VERSION="${RELEASE_VERSION:?RELEASE_VERSION is required}"

IMAGE="${IMAGE:?IMAGE is required}"

if [ ! -f "${IMAGE}.bz2" ]; then
  echo "ERROR: Compressed image ${IMAGE}.bz2 not found. Run 'make image-release' first." >&2
  exit 1
fi

# Determine the previous tag to generate changelog
PREVIOUS_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)

if [ -n "$PREVIOUS_TAG" ]; then
  echo "Generating changelog since ${PREVIOUS_TAG}..."
  CHANGELOG=$(git log --pretty=format:"- %s" "${PREVIOUS_TAG}..HEAD")
else
  echo "No previous tag found, generating full changelog..."
  CHANGELOG=$(git log --pretty=format:"- %s")
fi

if [ -z "$CHANGELOG" ]; then
  CHANGELOG="- No changes since last release"
fi

RELEASE_BODY="## Town OS ${RELEASE_VERSION}

### Changes

${CHANGELOG}
"

# Tag the main branch
echo "Tagging main branch as ${RELEASE_VERSION}..."
git tag -fa "${RELEASE_VERSION}" main -m "Release ${RELEASE_VERSION}"
git push --force origin "${RELEASE_VERSION}"

# Gitea API base — derive from git remote or allow override
GITEA_URL="${GITEA_URL:-https://gitea.com}"
GITEA_REPO="${GITEA_REPO:-town-os/install}"
API="${GITEA_URL}/api/v1/repos/${GITEA_REPO}"

if [ -z "${GITEA_TOKEN:-}" ]; then
  echo "ERROR: GITEA_TOKEN is required for API authentication." >&2
  exit 1
fi

# Create Gitea release via API
echo "Creating Gitea release ${RELEASE_VERSION}..."
RELEASE_RESPONSE=$(curl -sf -X POST "${API}/releases" \
  -H "Authorization: token ${GITEA_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg tag "${RELEASE_VERSION}" \
    --arg name "Town OS ${RELEASE_VERSION}" \
    --arg body "${RELEASE_BODY}" \
    '{tag_name: $tag, name: $name, body: $body}')")

RELEASE_ID=$(echo "${RELEASE_RESPONSE}" | jq -r '.id')

# Upload compressed image as release attachment
echo "Uploading ${IMAGE}.bz2..."
curl -sf -X POST "${API}/releases/${RELEASE_ID}/assets?name=$(basename "${IMAGE}.bz2")" \
  -H "Authorization: token ${GITEA_TOKEN}" \
  -H "Content-Type: application/octet-stream" \
  --data-binary "@${IMAGE}.bz2"

echo "Release ${RELEASE_VERSION} published successfully."
