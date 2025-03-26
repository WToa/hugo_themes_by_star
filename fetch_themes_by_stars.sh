#!/bin/bash

. .env.local

OUTPUT_FILE="README.md"

# File paths
THEMES_DATA=$(mktemp)
TEMP_DATA=$(mktemp)
SORTED_DATA=$(mktemp)

# Function to extract GitHub repository information
get_github_info() {
	repo_url=$1

	# Ensure URL has https:// prefix
	if [[ ! $repo_url =~ ^https?:// ]]; then
		repo_url="https://$repo_url"
	fi

	# Extract owner and repo from the GitHub URL
	if [[ $repo_url =~ github\.com/([^/]+)/([^/]+) ]]; then
		owner=${BASH_REMATCH[1]}
		repo=${BASH_REMATCH[2]}
		repo=${repo%.git} # Remove .git extension if present

		# Handle subpaths in repository URLs (e.g., "owner/repo/v2")
		if [[ $repo =~ ([^/]+)(/.*) ]]; then
			repo=${BASH_REMATCH[1]}
		fi
	else
		echo "0|Unknown|$repo_url"
		return
	fi

	# Set up API call
	api_url="https://api.github.com/repos/$owner/$repo"
	if [ -n "$GITHUB_TOKEN" ]; then
		response=$(curl -s -L -H "Authorization: token $GITHUB_TOKEN" "$api_url")
	else
		response=$(curl -s -L "$api_url")
	fi

	# Check if we hit rate limit
	if echo "$response" | grep -q "API rate limit exceeded"; then
		echo "GitHub API rate limit exceeded. Please wait or use a token." >&2
		echo "0|$owner/$repo|$repo_url"
		return
	fi

	# Extract star count using a more reliable method
	stars=$(echo "$response" | grep -o '"stargazers_count":[[:space:]]*[0-9]*' | head -1 | grep -o '[0-9]*')

	# If stars is empty, try alternative parsing
	if [ -z "$stars" ]; then
		# Try with different JSON format
		stars=$(echo "$response" | grep -o '"stargazers_count": [0-9]*' | head -1 | grep -o '[0-9]*')
	fi

	# If still empty, check for error in response
	if [ -z "$stars" ]; then
		# Print debug info
		echo "Warning: Could not extract star count for $owner/$repo" >&2
		echo "API Response: $response" >&2
		stars=0
	fi

	echo "$stars|$owner/$repo|$repo_url"
}

# Function to extract GitLab repository information
get_gitlab_info() {
	repo_url=$1

	# Ensure URL has https:// prefix
	if [[ ! $repo_url =~ ^https?:// ]]; then
		repo_url="https://$repo_url"
	fi

	# Extract project path from the GitLab URL
	if [[ $repo_url =~ gitlab\.com/(.+)$ ]]; then
		project_path=${BASH_REMATCH[1]}
		# Remove .git extension if present
		project_path=${project_path%.git}
	else
		echo "0|Unknown|$repo_url"
		return
	fi

	# URL encode the project path
	encoded_path=$(echo "$project_path" | sed 's|/|%2F|g')

	# Call GitLab API
	api_url="https://gitlab.com/api/v4/projects/$encoded_path"
	response=$(curl -s "$api_url")

	# Extract star count - use grep with head to ensure only one line is returned
	stars=$(echo "$response" | grep -o '"star_count":[0-9]*' | head -1 | grep -o '[0-9]*')

	# If stars is empty, try alternative parsing
	if [ -z "$stars" ]; then
		# Try with different JSON format
		stars=$(echo "$response" | grep -o '"star_count": [0-9]*' | head -1 | grep -o '[0-9]*')
	fi

	if [ -z "$stars" ]; then
		echo "Warning: Could not extract star count for GitLab project $project_path" >&2
		echo "API Response: $(echo "$response" | grep -o '"message":"[^"]*"' || echo 'No error message')" >&2
		stars=0
	fi

	echo "$stars|$project_path|$repo_url"
}

# Get list of Hugo themes
echo "Fetching Hugo themes list..."
curl -s https://raw.githubusercontent.com/gohugoio/hugoThemesSiteBuilder/refs/heads/main/themes.txt >"$THEMES_DATA"
total_themes=$(wc -l <"$THEMES_DATA")
echo "Found $total_themes themes to process"

# Create README.md header
cat >"$OUTPUT_FILE" <<EOF
# Hugo Themes Sorted by GitHub/GitLab Stars

This list is automatically generated using the [Hugo Themes Site Builder](https://github.com/gohugoio/hugoThemesSiteBuilder) data.
Script last run: $(date -u)

| Repository | Stars |
|------------|-------|
EOF

# Process each theme repository and get star count
echo "Processing themes and fetching star counts..."
counter=0
skipped=0
while IFS= read -r repo_url; do
	# Skip empty lines
	if [ -z "$repo_url" ]; then
		continue
	fi

	counter=$((counter + 1))

	# Skip URLs that are not from GitHub or GitLab
	if [[ "$repo_url" != *github.com* ]] && [[ "$repo_url" != *gitlab.com* ]]; then
		echo "Skipping non-GitHub/GitLab URL: $repo_url"
		skipped=$((skipped + 1))
		continue
	fi

	echo "Processing ($counter/$total_themes): $repo_url"

	# Get information based on whether it's GitHub or GitLab
	if [[ "$repo_url" == *github.com* ]]; then
		info=$(get_github_info "$repo_url")
	elif [[ "$repo_url" == *gitlab.com* ]]; then
		info=$(get_gitlab_info "$repo_url")
	fi

	echo "$info" >>"$TEMP_DATA"

done <"$THEMES_DATA"

echo "Processed $counter themes, skipped $skipped non-GitHub/GitLab URLs"

# Sort themes by stars (descending)
echo "Sorting themes by star count..."
sort -nr -t'|' -k1 "$TEMP_DATA" >"$SORTED_DATA"

# Add the sorted themes to the README.md
while IFS="|" read -r stars repo_path repo_url; do
	echo "| [$repo_path]($repo_url) | $stars |" >>"$OUTPUT_FILE"
done <"$SORTED_DATA"

# Clean up temporary files
rm "$THEMES_DATA" "$TEMP_DATA" "$SORTED_DATA"

echo "Done! README.md has been created at $OUTPUT_FILE"
