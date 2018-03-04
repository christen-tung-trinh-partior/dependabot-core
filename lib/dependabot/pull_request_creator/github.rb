# frozen_string_literal: true

require "octokit"
require "securerandom"
require "dependabot/pull_request_creator"
require "dependabot/pull_request_creator/commit_signer"

module Dependabot
  class PullRequestCreator
    class Github
      attr_reader :repo_name, :branch_name, :base_commit, :github_client,
                  :files, :pr_description, :pr_name, :commit_message,
                  :target_branch, :author_details, :signature_key,
                  :custom_labels

      def initialize(repo_name:, branch_name:, base_commit:, github_client:,
                     files:, commit_message:, pr_description:, pr_name:,
                     target_branch:, author_details:, signature_key:,
                     custom_labels:)
        @repo_name      = repo_name
        @branch_name    = branch_name
        @base_commit    = base_commit
        @target_branch  = target_branch
        @github_client  = github_client
        @files          = files
        @commit_message = commit_message
        @pr_description = pr_description
        @pr_name        = pr_name
        @author_details = author_details
        @signature_key  = signature_key
        @custom_labels  = custom_labels
      end

      def create
        return if branch_exists? && pull_request_exists?

        commit = create_commit
        branch = create_or_update_branch(commit)
        return unless branch

        create_label unless custom_labels || dependencies_label_exists?

        pull_request = create_pull_request
        add_label_to_pull_request(pull_request)
        pull_request
      end

      private

      def branch_exists?
        @branch_ref ||= github_client.ref(repo_name, "heads/#{branch_name}")
        @branch_ref.any? { |r| r.ref == "refs/heads/#{branch_name}" }
      rescue Octokit::NotFound
        false
      end

      def pull_request_exists?
        github_client.pull_requests(
          repo_name,
          head: "#{repo_name.split('/').first}:#{branch_name}",
          state: "all"
        ).any?
      end

      def create_commit
        tree = create_tree

        options = author_details&.any? ? { author: author_details } : {}

        if options[:author]&.any? && signature_key
          options[:author][:date] = Time.now.utc.iso8601
          options[:signature] = commit_signature(tree, options[:author])
        end

        github_client.create_commit(
          repo_name,
          commit_message,
          tree.sha,
          base_commit,
          options
        )
      end

      def create_tree
        file_trees = files.map do |file|
          if file.type == "submodule"
            {
              path: file.path.sub(%r{^/}, ""),
              mode: "160000",
              type: "commit",
              sha: file.content
            }
          else
            {
              path: file.path.sub(%r{^/}, ""),
              mode: "100644",
              type: "blob",
              content: file.content
            }
          end
        end

        github_client.create_tree(
          repo_name,
          file_trees,
          base_tree: base_commit
        )
      end

      def create_or_update_branch(commit)
        branch_exists? ? update_branch(commit) : create_branch(commit)
      end

      def create_branch(commit)
        github_client.create_ref(
          repo_name,
          "heads/#{branch_name}",
          commit.sha
        )
      rescue Octokit::UnprocessableEntity => error
        # Return quietly in the case of a race
        return nil if error.message.match?(/Reference already exists/i)
        raise if @retrying_branch_creation
        @retrying_branch_creation = true

        # Branch creation will fail if a branch called `dependabot` already
        # exists, since git won't be able to create a folder with the same name
        @branch_name = SecureRandom.hex[0..3] + @branch_name
        retry
      end

      def update_branch(commit)
        github_client.update_ref(
          repo_name,
          "heads/#{branch_name}",
          commit.sha,
          true
        )
      end

      def dependencies_label_exists?
        return (custom_labels - labels).empty? if custom_labels

        labels.any? { |l| l.match?(/dependenc/i) }
      end

      def labels
        @labels ||=
          github_client.
          labels(repo_name, per_page: 100).
          map(&:name)
      end

      def create_label
        github_client.add_label(
          repo_name, "dependencies", "0025ff",
          description: "Pull requests that update a dependency file"
        )
      rescue Octokit::UnprocessableEntity => error
        raise unless error.errors.first.fetch(:code) == "already_exists"
      end

      def add_label_to_pull_request(pull_request)
        # If a custom label is desired but doesn't exist, don't label the PR
        return if custom_labels && !dependencies_label_exists?

        label_names =
          if custom_labels then custom_labels
          elsif labels.any? { |l| l.match?(/dependenc/i) }
            [labels.find { |l| l.match?(/dependenc/i) }]
          else ["dependencies"]
          end

        github_client.add_labels_to_an_issue(
          repo_name,
          pull_request.number,
          label_names
        )
      end

      def create_pull_request
        github_client.create_pull_request(
          repo_name,
          target_branch || default_branch,
          branch_name,
          pr_name,
          pr_description
        )
      end

      def default_branch
        @default_branch ||= github_client.repository(repo_name).default_branch
      end

      def commit_signature(tree, author_details_with_date)
        CommitSigner.new(
          author_details: author_details_with_date,
          commit_message: commit_message,
          tree_sha: tree.sha,
          parent_sha: base_commit,
          signature_key: signature_key
        ).signature
      end
    end
  end
end
