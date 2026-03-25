#!/usr/bin/env bash
set -euo pipefail

if [ -z "${RELEASE_VERSION:-}" ]; then
  echo "ERROR: RELEASE_VERSION is required. Usage: make release RELEASE_VERSION=v1.0.0" >&2
  exit 1
fi

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
git tag -a "${RELEASE_VERSION}" main -m "Release ${RELEASE_VERSION}"
git push origin "${RELEASE_VERSION}"

# Create Gitea release with the compressed image as an attachment
echo "Creating Gitea release ${RELEASE_VERSION}..."
tea release create \
  --tag "${RELEASE_VERSION}" \
  --title "Town OS ${RELEASE_VERSION}" \
  --note "${RELEASE_BODY}" \
  --asset "${IMAGE}.bz2"

echo "Release ${RELEASE_VERSION} published successfully."
