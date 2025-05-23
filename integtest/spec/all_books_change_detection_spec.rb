# frozen_string_literal: true

require_relative 'spec_helper'

##
# Assertions about when books are rebuilt based on changes in source
# repositories or the book's configuration.
RSpec.describe 'building all books' do
  class Config
    attr_accessor :target_branch
    attr_accessor :checkout_branch
    attr_accessor :keep_hash

    def initialize(src, dest)
      @src = src
      @dest = dest
      @target_branch = nil
      @checkout_branch = nil
      @keep_hash = false
      @extra = proc {}
    end

    def convert_all
      conversion = @dest.prepare_convert_all @src.conf
      conversion.target_branch @target_branch if @target_branch
      conversion.keep_hash if @keep_hash
      @extra.call conversion
      conversion.convert
    end

    def extra
      @extra = proc
    end
  end
  describe 'change detection' do
    TWO_CHAPTERS = <<~ASCIIDOC
      = Title

      [[chapter1]]
      == Chapter 1
      Chapter 1 text

      [[chapter2]]
      == Chapter 2
      Some text.
    ASCIIDOC
    STACK_VERSIONS = 'shared/versions/stack/'
    ECE_VERSIONS = 'shared/versions/ece/'
    def self.build_twice(
        before_first_build:,
        before_second_build:
      )
      convert_before do |src, dest|
        config = Config.new src, dest
        # Allow the caller to customize the source.
        before_first_build.call(src, config)

        # Convert the first time. This should build the docs.
        config.convert_all

        # Take some action between the builds.
        before_second_build.call(src, config)

        # Convert the second time.
        config.convert_all

        # Checkout the files so we can assert about them.
        checkout = config.checkout_branch || config.target_branch
        dest.checkout_conversion branch: checkout
      end
    end

    def self.build_one_book_out_of_one_repo_twice(
        before_first_build: ->(src, config) {},
        before_second_build: ->(src, config) {}
      )
      build_twice(
        before_first_build: lambda do |src, config|
          repo = src.repo_with_file 'repo', 'index.asciidoc', TWO_CHAPTERS
          book = src.book 'Test'
          book.source repo, 'index.asciidoc'

          # Allow the caller to customize the source
          before_first_build.call src, config
        end,
        before_second_build: before_second_build
      )
      include_examples 'convert all basics'
    end

    def self.build_one_book_out_of_one_repo_and_then_out_of_two(
        before_second_build: ->(src, config) {}
      )
      build_twice(
        before_first_build: lambda do |src, _config|
          repo = src.repo_with_file 'repo', 'index.asciidoc', TWO_CHAPTERS
          book = src.book 'Test'
          book.source repo, 'index.asciidoc'
        end,
        before_second_build: init_second_book_and_customize(before_second_build)
      )
      include_examples 'convert all basics'
    end

    def self.init_second_book_and_customize(before_second_build)
      lambda do |src, config|
        repo2 = src.repo 'repo2'
        repo2.write 'garbage', 'junk'
        repo2.commit 'adding junk'
        src.book('Test').source repo2, 'garbage'

        before_second_build.call src, config
      end
    end

    def self.build_one_book_out_of_two_repos_twice(
        init: ->(src) { init_include src },
        before_first_build: ->(src, config) {},
        before_second_build: ->(src, config) {}
      )
      build_twice(
        before_first_build: lambda do |src, config|
          init.call src
          # Allow the caller to customize the source
          before_first_build.call src, config
        end,
        before_second_build: lambda do |src, config|
          before_second_build.call src, config
        end
      )
      include_examples 'convert all basics'
    end

    def self.init_include(src)
      repo1 = src.repo_with_file 'repo1', 'index.asciidoc', <<~ASCIIDOC
        #{TWO_CHAPTERS}
        Include between here
        include::../repo2/included.asciidoc[]
        and here.
      ASCIIDOC

      repo2 = src.repo_with_file 'repo2', 'included.asciidoc', 'included text'

      book = src.book 'Test'
      book.source repo1, 'index.asciidoc'
      book.source repo2, 'included.asciidoc'
    end

    def self.init_docs(src, included, body)
      include_ref = included.sub '{branch}', '{source_branch}'
      repo = src.repo_with_index 'repo', <<~ASCIIDOC
        include::{docs-root}/#{include_ref}[]

        #{body}
      ASCIIDOC
      docs_repo = src.repo 'docs'
      docs_repo.copy_shared_conf
      docs_repo.commit 'add shared conf'

      book = src.book 'Test'
      book.source repo, 'index.asciidoc'
      book.source docs_repo, included
    end

    def self.build_one_book_then_two_books(
        before_second_build: ->(src, config) {}
      )
      build_twice(
        before_first_build: lambda do |src, _config|
          src.book_and_repo 'repo', 'Test', 'Some text.'
        end,
        before_second_build: lambda do |src, config|
          src.book('Test2').source src.repo('repo'), 'index.asciidoc'

          before_second_build.call src, config
        end
      )
      include_examples 'build one book then two books'
    end

    shared_examples 'build one book then two books' do
      context 'the first build' do
        let(:out) { outputs[0] }
        include_examples 'commits changes'
        it 'does print that it is building the original book' do
          expect(out).to include('Test: Building master...')
        end
        it "doesn't print that it is building the new book" do
          # The new book doesn't exist at this point in the test
          expect(out).not_to include('Test2: Building master...')
        end
      end
      page_context 'html/test/current/chapter.html'
    end

    shared_examples 'toc and version drop down' do
      shared_examples 'correct' do
        context 'the version drop down' do
          let(:master_option) do
            <<~HTML.strip
              <option value="master"#{master_selected}>master</option>
            HTML
          end
          let(:foo_option) do
            <<~HTML.strip
              <option value="foo"#{foo_selected}>foo</option>
            HTML
          end
          it 'contains all versions' do
            expect(body).to include("#{master_option}#{foo_option}")
          end
        end
        context 'the toc' do
          def chapter(index)
            <<~HTML
              <li><span class="chapter"><a href="chapter#{index}.html">Chapter #{index}</a></span>
              </li>
            HTML
          end
          it 'contains all chapters' do
            expect(body).to include("#{chapter 1}#{chapter 2}")
          end
        end
      end
      shared_examples 'correct for branch' do |branch|
        page_context 'index.html', "html/test/#{branch}/index.html" do
          include_examples 'correct'
        end
        page_context 'toc.html', "html/test/#{branch}/toc.html" do
          include_examples 'correct'
        end
        page_context 'index.html', "raw/test/#{branch}/index.html" do
          include_examples 'correct'
        end
        page_context 'toc.html', "raw/test/#{branch}/toc.html" do
          include_examples 'correct'
        end
      end
      context 'the master branch' do
        let(:master_selected) { ' selected' }
        let(:foo_selected) { '' }
        include_examples 'correct for branch', 'master'
      end
      context 'the current branch' do
        let(:master_selected) { ' selected' }
        let(:foo_selected) { '' }
        include_examples 'correct for branch', 'current'
      end
      context 'the foo branch' do
        let(:master_selected) { '' }
        let(:foo_selected) { ' selected' }
        include_examples 'correct for branch', 'foo'
      end
    end

    shared_examples 'second build is noop' do
      context 'the second build' do
        let(:out) { outputs[1] }
        it "doesn't print that it is building any books" do
          expect(out).not_to include(': Building ')
        end
        include_examples "doesn't have anything to push"
      end
    end
    shared_examples "the second build doesn't have anything to push" do
      context 'the second build' do
        let(:out) { outputs[1] }
        include_examples "doesn't have anything to push"
      end
    end
    shared_examples "doesn't have anything to push" do
      it 'prints that it is not pushing anything' do
        expect(out).to include('No changes to push')
      end
    end

    shared_examples 'second build is not a noop' do
      context 'the second build' do
        let(:out) { outputs[1] }
        include_examples 'builds all books'
      end
    end
    shared_examples 'second build only changes chapter2' do
      page_context 'html/test/current/chapter2.html' do
        it 'includes the new text' do
          expect(body).to include('New text')
        end
      end
      context 'the sitemap' do
        context 'the second commit' do
          let(:commit_info) { @dest.commit_info_for_file('html/sitemap.xml') }
          # These assertions rely on the shape of `git show -- <file>`
          it 'updates the changed page' do
            expect(commit_info).to include(<<~XML)
              <loc>https://www.elastic.co/guide/test/current/chapter2.html</loc>
            XML
          end
          it "doesn't update the unchanged page" do
            expect(commit_info).not_to include(<<~XML)
              <loc>https://www.elastic.co/guide/test/current/chapter1.html</loc>
            XML
          end
        end
      end
    end

    context 'when building one book out of one repo twice' do
      context 'when the second build is a noop' do
        context 'because there are no changes to the source repo' do
          build_one_book_out_of_one_repo_twice
          include_examples 'second build is noop'
        end
        context 'even when there are no changes to the kibana repo' do
          build_one_book_out_of_one_repo_twice(
            before_first_build: lambda do |src, _config|
              # The kibana link checking requires a few things:
              # 1. A repo named kibana
              # 2. A special links file in the repo
              # 3. A book at `en/kibana`
              kibana_repo = src.repo_with_index 'kibana', 'words'

              # TODO: remove as part of https://github.com/elastic/docs/issues/2264,
              # and make "main" the default branch for all repos.
              kibana_repo.rename_branch 'main'

              kibana_repo.write(
                'src/core/public/doc_links/doc_links_service.ts',
                'text but no links actually'
              )
              kibana_repo.commit 'add links file'
              kibana_book = src.book 'Kibana', prefix: 'en/kibana'
              kibana_book.source kibana_repo, 'index.asciidoc'

              # TODO: remove as part of https://github.com/elastic/docs/issues/2264
              kibana_book.branches = [{ "main": 'master' }]
              kibana_book.live_branches = ['main']
              kibana_book.current_branch = 'main'
            end
          )
          include_examples 'second build is noop'
        end
        context 'even when there are unrelated changes source repo' do
          build_one_book_out_of_one_repo_twice(
            before_second_build: lambda do |src, _config|
              repo = src.repo 'repo'
              repo.write 'garbage', 'junk'
              repo.commit 'adding junk'
            end
          )
          include_examples 'second build is noop'
        end
        context 'even when there are noop changes source repo' do
          build_one_book_out_of_one_repo_twice(
            before_second_build: lambda do |src, _config|
              repo = src.repo 'repo'
              repo.write 'index.asccidoc', TWO_CHAPTERS + '  '
              repo.commit 'adding junk'
            end
          )
          include_examples 'second build is noop'
        end
        context 'when --keep_hash is specified and there are related ' \
                'changes source repo' do
          build_one_book_out_of_one_repo_twice(
            before_second_build: lambda do |src, config|
              repo = src.repo 'repo'
              repo.write 'index.asciidoc', <<~ASCIIDOC
                = Title

                [[chapter]]
                == Chapter
                New text.
              ASCIIDOC
              repo.commit 'changed text'

              config.keep_hash = true
            end
          )
          include_examples 'second build is noop'
        end
        context 'when --keep_hash is specified and there is a new branch' do
          build_one_book_out_of_one_repo_twice(
            before_second_build: lambda do |src, config|
              repo = src.repo 'repo'
              repo.switch_to_new_branch 'foo'
              book = src.book 'Test'
              book.branches.push 'foo'
              config.extra(&:keep_hash)
            end
          )
          context 'the second build' do
            let(:out) { outputs[1] }
            it "doesn't print that it is building the first branch" do
              # The original book hasn't changed so we don't rebuild it
              expect(out).not_to include('Test: Building master...')
            end
            it "doesn't print that it is building the second branch" do
              expect(out).not_to include('Test: Building foo...')
            end
            it 'does print that it is pushing changes' do
              # This is because the TOC includes the new branch. That isn't
              # great but it isn't too bad.
              expect(out).to include('Pushing changes')
            end
          end
        end
        context 'when --keep_hash and --sub_dir are specified but there are ' \
                'unrelated changes' do
          build_one_book_out_of_one_repo_twice(
            before_second_build: lambda do |src, config|
              repo = src.repo 'repo'
              repo.write 'dummy', 'dummy'
              repo.commit 'dummy'

              config.extra do |conversion|
                conversion.keep_hash.sub_dir(repo, 'master')
              end
            end
          )
          include_examples "the second build doesn't have anything to push"
        end
        context 'even when there is a new target branch' do
          # Since we fork the target_branch to master we won't have anything
          # to commit if the book doesn't change
          build_one_book_out_of_one_repo_twice(
            before_second_build: lambda do |_src, config|
              config.target_branch = 'new_target'
              config.checkout_branch = 'master'
            end
          )
          include_examples 'second build is noop'
        end
      end
      context "when the second build isn't a noop" do
        context 'because the source repo changes' do
          build_one_book_out_of_one_repo_twice(
            before_second_build: lambda do |src, _config|
              repo = src.repo 'repo'
              repo.write 'index.asciidoc', <<~ASCIIDOC
                #{TWO_CHAPTERS}
                New text.
              ASCIIDOC
              repo.commit 'changed text'
            end
          )
          include_examples 'second build is not a noop'
          include_examples 'second build only changes chapter2'
        end
        context 'because there is a target_branch and we have changes' do
          # We always fork the target_branch from master so if the target
          # branch contains any changes from master we rebuild them every time.
          build_one_book_out_of_one_repo_twice(
            before_first_build: lambda do |_src, config|
              config.target_branch = 'new_target'
            end
          )
          include_examples 'second build is not a noop'
          context 'the first build' do
            let(:out) { outputs[0] }
            it 'logs that it is forking from master' do
              expect(out).to include('Forking <new_target> from master')
            end
          end
          context 'the second build' do
            let(:out) { outputs[1] }
            it 'logs that it is forking from master' do
              expect(out).to include('Forking <new_target> from master')
            end
          end
        end
        context 'because we remove the target_branch' do
          # Removing the target branch causes us to build into the *empty*
          # master branch. Being empty, there aren't any books in it to
          # consider "already built".
          build_one_book_out_of_one_repo_twice(
            before_first_build: lambda do |_src, config|
              config.target_branch = 'new_target'
            end,
            before_second_build: lambda do |_src, config|
              config.target_branch = nil # nil means don't override
            end
          )
          include_examples 'second build is not a noop'
        end
        context 'because we add a new branch' do
          build_one_book_out_of_one_repo_twice(
            before_second_build: lambda do |src, _config|
              repo = src.repo 'repo'
              repo.switch_to_new_branch 'foo'
              book = src.book 'Test'
              book.branches.push 'foo'
            end
          )
          context 'the second build' do
            let(:out) { outputs[1] }
            include_examples 'commits changes'
          end
          file_context 'html/branches.yaml' do
            it 'includes the original branch' do
              expect(contents).to include('Test/index.asciidoc/master')
            end
            it 'includes the added branch' do
              expect(contents).to include('Test/index.asciidoc/foo')
            end
          end
          include_examples 'toc and version drop down'
          let(:current) { 'master' }
        end
        context 'because we change the current branch' do
          build_one_book_out_of_one_repo_twice(
            before_first_build: lambda do |src, _config|
              repo = src.repo 'repo'
              repo.switch_to_new_branch 'foo'
              repo.write 'index.asciidoc', <<~ASCIIDOC
                = Title

                [[chapter]]
                == Chapter
                Different text.
              ASCIIDOC
              repo.commit 'change foo'
              book = src.book 'Test'
              book.branches.push 'foo'
            end,
            before_second_build: lambda do |src, _config|
              book = src.book 'Test'
              book.current_branch = 'foo'
            end
          )
          context 'the second build' do
            let(:out) { outputs[1] }
            include_examples 'commits changes'
          end
          file_context 'html/branches.yaml' do
            it 'includes the original branch' do
              expect(contents).to include('Test/index.asciidoc/master')
            end
            it 'includes the added branch' do
              expect(contents).to include('Test/index.asciidoc/foo')
            end
          end
          # TODO: these are known to fail!
          # let(:current) { 'foo' }
          # include_examples 'toc and version drop down'
          # TODO: check that we wrote different text into the current book
        end
        context 'because we remove a branch from the book' do
          build_one_book_out_of_one_repo_twice(
            before_first_build: lambda do |src, _config|
              repo = src.repo 'repo'
              repo.switch_to_new_branch 'foo'
              repo.switch_to_new_branch 'bar'
              book = src.book 'Test'
              book.branches.push 'foo'
              book.branches.push 'bar'
            end,
            before_second_build: lambda do |src, _config|
              book = src.book 'Test'
              book.branches.delete 'bar'
            end
          )
          context 'the second build' do
            let(:out) { outputs[1] }
            include_examples 'commits changes'
          end
          file_context 'html/branches.yaml' do
            it 'includes the original master branch' do
              expect(contents).to include('Test/index.asciidoc/master')
            end
            it 'includes the original extra branch' do
              expect(contents).to include('Test/index.asciidoc/foo')
            end
            it "doesn't include the removed branch" do
              expect(contents).not_to include('Test/index.asciidoc/bar')
            end
          end
          include_examples 'toc and version drop down'
          let(:current) { 'master' }
        end
        context 'because we add a branch to the book and specify ' \
                '--keep_hash and --sub_dir' do
          build_one_book_out_of_one_repo_twice(
            before_second_build: lambda do |src, config|
              repo = src.repo 'repo'
              book = src.book 'Test'
              book.branches.push 'foo'
              config.extra do |conversion|
                conversion.keep_hash.sub_dir(repo, 'foo')
              end
            end
          )
          context 'the second build' do
            let(:out) { outputs[1] }
            it 'builds the new branch' do
              expect(out).to include 'Test: Building foo...'
            end
            include_examples 'commits changes'
          end
        end
        context 'because we add a source to the book and specify ' \
                '--keep_hash and --sub_dir' do
          build_one_book_out_of_one_repo_twice(
            before_second_build: lambda do |src, config|
              repo2 = src.repo 'repo2'
              repo2.write 'dummy', 'words'
              repo2.commit 'init'
              book = src.book 'Test'
              book.source repo2, 'not_used_actually'
              repo = src.repo 'repo'
              repo.switch_to_new_branch 'subbed'
              repo.write 'index.asciidoc', TWO_CHAPTERS + "\nmore words"
              repo.commit 'sub'
              config.extra do |conversion|
                conversion.keep_hash.sub_dir(repo, 'master')
              end
            end
          )
          # The new branch is ignored because it wasn't used last time
          include_examples 'second build is not a noop'
          context 'the second build' do
            let(:out) { outputs[1] }
            it 'prints that it is skipping the new source' do
              expect(out).to include(
                'Test: Skipping new repo repo2 for branch master.'
              )
            end
          end
        end
      end
    end

    context 'when building one book out of one repo and then out of two' do
      context 'when the second build is a noop' do
        context 'because it was run with --keep_hash' do
          build_one_book_out_of_one_repo_and_then_out_of_two(
            before_second_build: lambda do |_src, config|
              config.keep_hash = true
            end
          )
          include_examples 'second build is noop'
        end
      end
      context "when the second build isn't a noop" do
        context 'because it was run without any special flags' do
          build_one_book_out_of_one_repo_and_then_out_of_two
          include_examples 'second build is not a noop'
        end
      end
    end

    context 'when building one book out of two repos twice' do
      def self.add_branch(src)
        repo1 = src.repo 'repo1'
        repo1.switch_to_new_branch 'foo'
        repo2 = src.repo 'repo2'
        repo2.switch_to_new_branch 'foo'
        book = src.book 'Test'
        book.branches.push 'foo'
      end
      context 'when the second build is a noop' do
        context 'because there are no changes to the either repo' do
          build_one_book_out_of_two_repos_twice
          include_examples 'second build is noop'
        end
        context 'because there are unrelated changes to the index repo' do
          build_one_book_out_of_two_repos_twice(
            before_second_build: lambda do |src, _config|
              repo1 = src.repo 'repo1'
              repo1.write 'garbage', 'junk'
              repo1.commit 'adding junk'
            end
          )
          include_examples 'second build is noop'
        end
        context 'because there are unrelated changes to the included repo' do
          build_one_book_out_of_two_repos_twice(
            before_second_build: lambda do |src, _config|
              repo2 = src.repo 'repo2'
              repo2.write 'garbage', 'junk'
              repo2.commit 'adding junk'
            end
          )
          include_examples 'second build is noop'
        end
        context 'because there is an unrelated change in a mapped branch' do
          build_one_book_out_of_two_repos_twice(
            before_first_build: lambda do |src, _config|
              book = src.book 'Test'
              repo2 = src.repo 'repo2'
              book.source repo2, 'included.asciidoc',
                          map_branches: { 'master': 'override' }
              repo2.switch_to_new_branch 'override'
            end,
            before_second_build: lambda do |src, _config|
              repo2 = src.repo 'repo2'
              repo2.write 'garbage', 'junk'
              repo2.commit 'adding junk'
            end
          )
          include_examples 'second build is noop'
        end
        context 'because we add a new branch and specify --keep_hash ' \
                'and --sub_dir on the new branch with one repo' do
          build_one_book_out_of_two_repos_twice(
            before_second_build: lambda do |src, config|
              add_branch src
              config.extra do |conversion|
                conversion.keep_hash.sub_dir(src.repo('repo1'), 'foo')
              end
            end
          )
          context 'the second build' do
            let(:out) { outputs[1] }
            include_examples 'commits changes'
            it "doesn't print that it is building any branch" do
              # The original book hasn't changed so we don't rebuild it
              expect(out).not_to include('Test: Building')
            end
          end
        end
        context "because the docs repo's attribute file doesn't change" do
          build_one_book_out_of_two_repos_twice(
            init: lambda do |src|
              init_docs src, 'shared/attributes.asciidoc', '{stack}'
            end
          )
          include_examples 'second build is noop'
        end
        context 'even though there is an unrelated change to the docs repo' do
          build_one_book_out_of_two_repos_twice(
            init: lambda do |src|
              init_docs src, 'shared/attributes.asciidoc', '{stack}'
            end,
            before_second_build: lambda do |src, config|
              docs_repo = src.repo 'docs'
              docs_repo.write 'shared/foo.asciidoc', 'bar'
              docs_repo.commit 'changed'
              config.keep_hash = true
            end
          )
          include_examples 'second build is noop'
        end
        # It is important that changes to the docs repo don't trigger a rebuild
        # when `--keep_hash` is specified or else every time we change this
        # file we'll rebuild all books in every PR build. That is a waste of
        # time and a potential source of spurious errors.
        context "because the docs repo's attributes file doesn't change but " \
                'the build has --keep_hash' do
          build_one_book_out_of_two_repos_twice(
            init: lambda do |src|
              init_docs src, 'shared/attributes.asciidoc', '{stack}'
            end,
            before_second_build: lambda do |src, config|
              docs_repo = src.repo 'docs'
              docs_repo.append 'shared/attributes.asciidoc', <<~ASCIIDOC
                :stack: Changed Stack
              ASCIIDOC
              docs_repo.commit 'changed'
              config.keep_hash = true
            end
          )
          include_examples 'second build is noop'
        end
      end
      context "when the second build isn't a noop" do
        context 'because the index repo changes' do
          build_one_book_out_of_two_repos_twice(
            before_second_build: lambda do |src, _config|
              repo1 = src.repo 'repo1'
              text = repo1.read 'index.asciidoc'
              repo1.write 'index.asciidoc', text + 'New text'
              repo1.commit 'changed text'
            end
          )
          include_examples 'second build is not a noop'
          include_examples 'second build only changes chapter2'
        end
        context 'because the included repo changes' do
          build_one_book_out_of_two_repos_twice(
            before_second_build: lambda do |src, _config|
              repo2 = src.repo 'repo2'
              repo2.write 'included.asciidoc', 'New text'
              repo2.commit 'changed text'
            end
          )
          include_examples 'second build is not a noop'
          include_examples 'second build only changes chapter2'
        end
        context "because a repo's branch mapping changes" do
          build_one_book_out_of_two_repos_twice(
            before_second_build: lambda do |src, _config|
              book = src.book 'Test'
              repo2 = src.repo 'repo2'
              book.source repo2, 'included.asciidoc',
                          map_branches: { 'master': 'override' }
              repo2.switch_to_new_branch 'override'
            end
          )
          include_examples 'second build is not a noop'
        end
        context 'because there is a change in a mapped branch' do
          build_one_book_out_of_two_repos_twice(
            before_first_build: lambda do |src, _config|
              book = src.book 'Test'
              repo2 = src.repo 'repo2'
              book.source repo2, 'included.asciidoc',
                          map_branches: { 'master': 'override' }
              repo2.switch_to_new_branch 'override'
            end,
            before_second_build: lambda do |src, _config|
              repo2 = src.repo 'repo2'
              repo2.write 'included.asciidoc', 'New text'
              repo2.commit 'changed text'
            end
          )
          include_examples 'second build is not a noop'
          include_examples 'second build only changes chapter2'
        end
        context 'because we add a new branch' do
          build_one_book_out_of_two_repos_twice(
            before_second_build: lambda do |src, _config|
              add_branch src
            end
          )
          context 'the second build' do
            let(:out) { outputs[1] }
            include_examples 'commits changes'
            it "doesn't print that it is building the original branch" do
              expect(out).not_to include('Test: Building master...')
            end
          end
        end
        context 'because we add a new branch and specify --keep_hash ' \
                'and --sub_dir on the new branch with both repos' do
          build_one_book_out_of_two_repos_twice(
            before_second_build: lambda do |src, config|
              add_branch src
              config.extra do |conversion|
                conversion.keep_hash
                          .sub_dir(src.repo('repo1'), 'foo')
                          .sub_dir(src.repo('repo2'), 'foo')
              end
            end
          )
          context 'the second build' do
            let(:out) { outputs[1] }
            include_examples 'commits changes'
            it "doesn't print that it is building the original branch" do
              expect(out).not_to include('Test: Building master...')
            end
            it 'prints that is buildin the new branch' do
              expect(out).to include('Test: Building foo...')
            end
          end
        end
        context "because the docs repo's attribute file changes" do
          build_one_book_out_of_two_repos_twice(
            init: lambda do |src|
              init_docs src, 'shared/attributes.asciidoc', '{stack}'
            end,
            before_second_build: lambda do |src, _config|
              docs_repo = src.repo 'docs'
              docs_repo.append 'shared/attributes.asciidoc', <<~ASCIIDOC
                :stack: Changed Stack
              ASCIIDOC
              docs_repo.commit 'changed'
            end
          )
          include_examples 'second build is not a noop'
        end
        context "because the docs repo's stack version file " \
                'for master changes' do
          build_one_book_out_of_two_repos_twice(
            init: lambda do |src|
              init_docs src, "#{STACK_VERSIONS}/{branch}.asciidoc", '{version}'
            end,
            before_second_build: lambda do |src, _config|
              docs_repo = src.repo 'docs'
              docs_repo.append "#{STACK_VERSIONS}/master.asciidoc", <<~ASCIIDOC
                :version: pig
              ASCIIDOC
              docs_repo.commit 'changed'
            end
          )
          include_examples 'second build is not a noop'
        end
        context "because the docs repo's current stack version file changes" do
          build_one_book_out_of_two_repos_twice(
            init: lambda do |src|
              init_docs src, "#{STACK_VERSIONS}/current.asciidoc", '{version}'
            end,
            before_second_build: lambda do |src, _config|
              docs_repo = src.repo 'docs'
              docs_repo.write "#{STACK_VERSIONS}/current.asciidoc", <<~ASCIIDOC
                include::master.asciidoc[]
              ASCIIDOC
              docs_repo.commit 'changed'
            end
          )
          include_examples 'second build is not a noop'
        end
        context "because the file referenced by the docs repo's current " \
                'stack version file changes' do
          build_one_book_out_of_two_repos_twice(
            init: lambda do |src|
              path = "#{STACK_VERSIONS}/current.asciidoc"
              init_docs src, path, '{version}'
              docs_repo = src.repo 'docs'
              docs_repo.write path, 'include::master.asciidoc[]'
              docs_repo.commit 'use master'
            end,
            before_second_build: lambda do |src, _config|
              docs_repo = src.repo 'docs'
              docs_repo.append "#{STACK_VERSIONS}/master.asciidoc", <<~ASCIIDOC
                :version: cow
              ASCIIDOC
              docs_repo.commit 'changed'
            end
          )
          include_examples 'second build is not a noop'
        end
        context "because the docs repo's ece version file " \
                'for master changes' do
          build_one_book_out_of_two_repos_twice(
            init: lambda do |src|
              init_docs src,
                        "#{ECE_VERSIONS}/{branch}.asciidoc", '{ece-version}'
            end,
            before_second_build: lambda do |src, _config|
              docs_repo = src.repo 'docs'
              docs_repo.append "#{ECE_VERSIONS}/master.asciidoc", <<~ASCIIDOC
                :ece-version: pig
              ASCIIDOC
              docs_repo.commit 'changed'
            end
          )
          include_examples 'second build is not a noop'
        end
        context "because the docs repo's current ece version file changes" do
          build_one_book_out_of_two_repos_twice(
            init: lambda do |src|
              init_docs src, "#{ECE_VERSIONS}/current.asciidoc", '{ece-version}'
            end,
            before_second_build: lambda do |src, _config|
              docs_repo = src.repo 'docs'
              docs_repo.write "#{ECE_VERSIONS}/current.asciidoc", <<~ASCIIDOC
                include::master.asciidoc[]
              ASCIIDOC
              docs_repo.commit 'changed'
            end
          )
          include_examples 'second build is not a noop'
        end
        context "because the file referenced by the docs repo's current " \
                'ece version file changes' do
          build_one_book_out_of_two_repos_twice(
            init: lambda do |src|
              path = "#{ECE_VERSIONS}/current.asciidoc"
              init_docs src, path, '{ece-version}'
              docs_repo = src.repo 'docs'
              docs_repo.write path, 'include::master.asciidoc[]'
              docs_repo.commit 'use master'
            end,
            before_second_build: lambda do |src, _config|
              docs_repo = src.repo 'docs'
              docs_repo.append "#{ECE_VERSIONS}/master.asciidoc", <<~ASCIIDOC
                :ece-version: cow
              ASCIIDOC
              docs_repo.commit 'changed'
            end
          )
          include_examples 'second build is not a noop'
        end
      end
    end

    context 'when building one book and then building two books' do
      context 'without any special flags' do
        build_one_book_then_two_books
        context 'the second build' do
          let(:out) { outputs[1] }
          include_examples 'commits changes'
          it "doesn't print that it is building the original book" do
            # The original book hasn't changed so we don't rebuild it
            expect(out).not_to include('Test: Building master...')
          end
          it 'does print that it is building the new book' do
            expect(out).to include('Test2: Building master...')
          end
        end
        page_context 'html/test2/current/chapter.html'
      end
      context 'when --keep_hash is specified' do
        build_one_book_then_two_books(
          before_second_build: lambda do |_src, config|
            config.keep_hash = true
          end
        )
        context 'the second build' do
          let(:out) { outputs[1] }
          it "doesn't print that it is building the original book" do
            # The original book hasn't changed so we don't rebuild it
            expect(out).not_to include('Test: Building master...')
          end
          it "doesn't print that it is building the new book" do
            expect(out).not_to include('Test2: Building master...')
          end
          it 'does print that it is pushing changes' do
            # This is because the TOC includes the new book. That isn't great
            # but it is fine.
            expect(out).to include('Pushing changes')
          end
        end
      end
    end
  end
end
