# frozen_string_literal: true

RSpec.describe Post do
  fab!(:coding_horror) { Fabricate(:coding_horror) }

  before { Oneboxer.stubs :onebox }

  let(:upload_path) { Discourse.store.upload_path }

  describe '#hidden_reasons' do
    context "when verifying enum sequence" do
      before do
        @hidden_reasons = Post.hidden_reasons
      end

      it "'flag_threshold_reached' should be at 1st position" do
        expect(@hidden_reasons[:flag_threshold_reached]).to eq(1)
      end

      it "'flagged_by_tl3_user' should be at 4th position" do
        expect(@hidden_reasons[:flagged_by_tl3_user]).to eq(4)
      end
    end
  end

  describe '#types' do
    context "when verifying enum sequence" do
      before do
        @types = Post.types
      end

      it "'regular' should be at 1st position" do
        expect(@types[:regular]).to eq(1)
      end

      it "'whisper' should be at 4th position" do
        expect(@types[:whisper]).to eq(4)
      end
    end
  end

  describe '#cook_methods' do
    context "when verifying enum sequence" do
      before do
        @cook_methods = Post.cook_methods
      end

      it "'regular' should be at 1st position" do
        expect(@cook_methods[:regular]).to eq(1)
      end

      it "'email' should be at 3rd position" do
        expect(@cook_methods[:email]).to eq(3)
      end
    end
  end

  # Help us build a post with a raw body
  def post_with_body(body, user = nil)
    args = post_args.merge(raw: body)
    args[:user] = user if user.present?
    Fabricate.build(:post, args)
  end

  it { is_expected.to validate_presence_of :raw }

  # Min/max body lengths, respecting padding
  it { is_expected.not_to allow_value("x").for(:raw) }
  it { is_expected.not_to allow_value("x" * (SiteSetting.max_post_length + 1)).for(:raw) }
  it { is_expected.not_to allow_value((" " * SiteSetting.min_post_length) + "x").for(:raw) }

  it { is_expected.to rate_limit }

  let(:topic) { Fabricate(:topic) }
  let(:post_args) do
    { user: topic.user, topic: topic }
  end

  describe 'scopes' do

    describe '#by_newest' do
      it 'returns posts ordered by created_at desc' do
        2.times do |t|
          Fabricate(:post, created_at: t.seconds.from_now)
        end
        expect(Post.by_newest.first.created_at).to be > Post.by_newest.last.created_at
      end
    end

    describe '#with_user' do
      it 'gives you a user' do
        Fabricate(:post, user: Fabricate.build(:user))
        expect(Post.with_user.first.user).to be_a User
      end
    end

  end

  describe "revisions and deleting/recovery" do
    context 'with a post without links' do
      let(:post) { Fabricate(:post, post_args) }

      before do
        post.trash!
        post.reload
      end

      it "doesn't create a new revision when deleted" do
        expect(post.revisions.count).to eq(0)
      end

      describe "recovery" do
        before do
          post.recover!
          post.reload
        end

        it "doesn't create a new revision when recovered" do
          expect(post.revisions.count).to eq(0)
        end
      end
    end

    context 'with a post with links' do
      let(:post) { Fabricate(:post_with_external_links) }
      before do
        post.trash!
        post.reload
      end

      describe 'recovery' do
        it 'recreates the topic_link records' do
          TopicLink.expects(:extract_from).with(post)
          post.recover!
        end
      end
    end
  end

  context 'with a post with notices' do
    let(:post) do
      post = Fabricate(:post, post_args)
      post.upsert_custom_fields(Post::NOTICE => { type: Post.notices[:returning_user], last_posted_at: 1.day.ago })
      post
    end

    it 'will have its notice cleared when post is trashed' do
      expect { post.trash! }.to change { post.custom_fields }.to({})
    end
  end

  describe "with_secure_uploads?" do
    let(:topic) { Fabricate(:topic) }
    let!(:post) { Fabricate(:post, topic: topic) }
    it "returns false if secure uploads is not enabled" do
      expect(post.with_secure_uploads?).to eq(false)
    end

    context "when secure uploads is enabled" do
      before do
        setup_s3
        SiteSetting.authorized_extensions = "pdf|png|jpg|csv"
        SiteSetting.secure_uploads = true
      end

      context "if login_required" do
        before { SiteSetting.login_required = true }

        it "returns true" do
          expect(post.with_secure_uploads?).to eq(true)
        end
      end

      context "if the topic category is read_restricted" do
        let(:category) { Fabricate(:private_category, group: Fabricate(:group)) }
        before do
          topic.change_category_to_id(category.id)
        end

        it "returns true" do
          expect(post.with_secure_uploads?).to eq(true)
        end
      end

      context "if the post is in a PM topic" do
        let(:topic) { Fabricate(:private_message_topic) }

        it "returns true" do
          expect(post.with_secure_uploads?).to eq(true)
        end
      end
    end
  end

  describe 'flagging helpers' do
    fab!(:post) { Fabricate(:post) }
    fab!(:user) { coding_horror }
    fab!(:admin) { Fabricate(:admin) }

    it 'is_flagged? is accurate' do
      PostActionCreator.off_topic(user, post)
      expect(post.reload.is_flagged?).to eq(true)

      PostActionDestroyer.destroy(user, post, :off_topic)
      expect(post.reload.is_flagged?).to eq(false)
    end

    it 'is_flagged? is true if flag was deferred' do
      result = PostActionCreator.off_topic(user, post)
      result.reviewable.perform(admin, :ignore)
      expect(post.reload.is_flagged?).to eq(true)
    end

    it 'is_flagged? is true if flag was cleared' do
      result = PostActionCreator.off_topic(user, post)
      result.reviewable.perform(admin, :disagree)
      expect(post.reload.is_flagged?).to eq(true)
    end

    it 'reviewable_flag is nil when ignored' do
      result = PostActionCreator.spam(user, post)
      expect(post.reviewable_flag).to eq(result.reviewable)

      result.reviewable.perform(admin, :ignore)
      expect(post.reviewable_flag).to be_nil
    end

    it 'reviewable_flag is nil when disagreed' do
      result = PostActionCreator.spam(user, post)
      expect(post.reviewable_flag).to eq(result.reviewable)

      result.reviewable.perform(admin, :disagree)
      expect(post.reload.reviewable_flag).to be_nil
    end
  end

  describe "maximum media embeds" do
    fab!(:newuser) { Fabricate(:user, trust_level: TrustLevel[0]) }
    let(:post_no_images) { Fabricate.build(:post, post_args.merge(user: newuser)) }
    let(:post_one_image) { post_with_body("![sherlock](http://bbc.co.uk/sherlock.jpg)", newuser) }
    let(:post_two_images) { post_with_body("<img src='http://discourse.org/logo.png'> <img src='http://bbc.co.uk/sherlock.jpg'>", newuser) }
    let(:post_with_avatars) { post_with_body('<img alt="smiley" title=":smiley:" src="/assets/emoji/smiley.png" class="avatar"> <img alt="wink" title=":wink:" src="/assets/emoji/wink.png" class="avatar">', newuser) }
    let(:post_with_favicon) { post_with_body('<img src="/images/favicons/discourse.png" class="favicon">', newuser) }
    let(:post_image_within_quote) { post_with_body('[quote]<img src="coolimage.png">[/quote]', newuser) }
    let(:post_image_within_code) { post_with_body('<code><img src="coolimage.png"></code>', newuser) }
    let(:post_image_within_pre) { post_with_body('<pre><img src="coolimage.png"></pre>', newuser) }
    let(:post_with_thumbnail) { post_with_body('<img src="/assets/emoji/smiley.png" class="thumbnail">', newuser) }
    let(:post_with_two_classy_images) { post_with_body("<img src='http://discourse.org/logo.png' class='classy'> <img src='http://bbc.co.uk/sherlock.jpg' class='classy'>", newuser) }
    let(:post_with_two_embedded_media) { post_with_body('<video width="950" height="700" controls><source src="https://bbc.co.uk/news.mp4" type="video/mp4"></video><audio controls><source type="audio/mpeg" src="https://example.com/audio.mp3"></audio>', newuser) }

    it "returns 0 images for an empty post" do
      expect(Fabricate.build(:post).embedded_media_count).to eq(0)
    end

    it "finds images from markdown" do
      expect(post_one_image.embedded_media_count).to eq(1)
    end

    it "finds images from HTML" do
      expect(post_two_images.embedded_media_count).to eq(2)
    end

    it "doesn't count avatars as images" do
      expect(post_with_avatars.embedded_media_count).to eq(0)
    end

    it "allows images by default" do
      expect(post_one_image).to be_valid
    end

    it "doesn't allow more than `min_trust_to_post_embedded_media`" do
      SiteSetting.min_trust_to_post_embedded_media = 4
      post_one_image.user.trust_level = 3
      expect(post_one_image).not_to be_valid
    end

    it "doesn't allow more than `min_trust_to_post_embedded_media` in a quote" do
      SiteSetting.min_trust_to_post_embedded_media = 4
      post_one_image.user.trust_level = 3
      expect(post_image_within_quote).not_to be_valid
    end

    it "doesn't allow more than `min_trust_to_post_embedded_media` in code" do
      SiteSetting.min_trust_to_post_embedded_media = 4
      post_one_image.user.trust_level = 3
      expect(post_image_within_code).not_to be_valid
    end

    it "doesn't allow more than `min_trust_to_post_embedded_media` in pre" do
      SiteSetting.min_trust_to_post_embedded_media = 4
      post_one_image.user.trust_level = 3
      expect(post_image_within_pre).not_to be_valid
    end

    it "doesn't allow more than `min_trust_to_post_embedded_media`" do
      SiteSetting.min_trust_to_post_embedded_media = 4
      post_one_image.user.trust_level = 4
      expect(post_one_image).to be_valid
    end

    it "doesn't count favicons as images" do
      PrettyText.stubs(:cook).returns(post_with_favicon.raw)
      expect(post_with_favicon.embedded_media_count).to eq(0)
    end

    it "doesn't count thumbnails as images" do
      PrettyText.stubs(:cook).returns(post_with_thumbnail.raw)
      expect(post_with_thumbnail.embedded_media_count).to eq(0)
    end

    it "doesn't count allowlisted images" do
      Post.stubs(:allowed_image_classes).returns(["classy"])
      # I dislike this, but passing in a custom allowlist is hard
      PrettyText.stubs(:cook).returns(post_with_two_classy_images.raw)
      expect(post_with_two_classy_images.embedded_media_count).to eq(0)
    end

    it "counts video and audio as embedded media" do
      expect(post_with_two_embedded_media.embedded_media_count).to eq(2)
    end

    context "with validation" do
      before do
        SiteSetting.newuser_max_embedded_media = 1
      end

      context 'with newuser' do
        it "allows a new user to post below the limit" do
          expect(post_one_image).to be_valid
        end

        it "doesn't allow more than the maximum number of images" do
          expect(post_two_images).not_to be_valid
        end

        it "doesn't allow more than the maximum number of embedded media items" do
          expect(post_with_two_embedded_media).not_to be_valid
        end

        it "doesn't allow a new user to edit their post to insert an image" do
          post_no_images.user.trust_level = TrustLevel[0]
          post_no_images.save
          expect {
            post_no_images.revise(post_no_images.user, raw: post_two_images.raw)
            post_no_images.reload
          }.not_to change(post_no_images, :raw)
        end
      end

      it "allows more images from a not-new account" do
        post_two_images.user.trust_level = TrustLevel[1]
        expect(post_two_images).to be_valid
      end
    end
  end

  describe "maximum attachments" do
    fab!(:newuser) { Fabricate(:user, trust_level: TrustLevel[0]) }
    let(:post_no_attachments) { Fabricate.build(:post, post_args.merge(user: newuser)) }
    let(:post_one_attachment) { post_with_body("<a class='attachment' href='/#{upload_path}/1/2082985.txt'>file.txt</a>", newuser) }
    let(:post_two_attachments) { post_with_body("<a class='attachment' href='/#{upload_path}/2/20947092.log'>errors.log</a> <a class='attachment' href='/#{upload_path}/3/283572385.3ds'>model.3ds</a>", newuser) }

    it "returns 0 attachments for an empty post" do
      expect(Fabricate.build(:post).attachment_count).to eq(0)
    end

    it "finds attachments from HTML" do
      expect(post_two_attachments.attachment_count).to eq(2)
    end

    context "with validation" do
      before do
        SiteSetting.newuser_max_attachments = 1
      end

      context 'with newuser' do
        it "allows a new user to post below the limit" do
          expect(post_one_attachment).to be_valid
        end

        it "doesn't allow more than the maximum" do
          expect(post_two_attachments).not_to be_valid
        end

        it "doesn't allow a new user to edit their post to insert an attachment" do
          post_no_attachments.user.trust_level = TrustLevel[0]
          post_no_attachments.save
          expect {
            post_no_attachments.revise(post_no_attachments.user, raw: post_two_attachments.raw)
            post_no_attachments.reload
          }.not_to change(post_no_attachments, :raw)
        end
      end

      it "allows more attachments from a not-new account" do
        post_two_attachments.user.trust_level = TrustLevel[1]
        expect(post_two_attachments).to be_valid
      end
    end
  end

  describe "links" do
    fab!(:newuser) { Fabricate(:user, trust_level: TrustLevel[0]) }
    let(:no_links) { post_with_body("hello world my name is evil trout", newuser) }
    let(:one_link) { post_with_body("[jlawr](http://www.imdb.com/name/nm2225369)", newuser) }
    let(:two_links) { post_with_body("<a href='http://disneyland.disney.go.com/'>disney</a> <a href='http://reddit.com'>reddit</a>", newuser) }
    let(:three_links) { post_with_body("http://discourse.org and http://discourse.org/another_url and http://www.imdb.com/name/nm2225369", newuser) }

    describe "raw_links" do
      it "returns a blank collection for a post with no links" do
        expect(no_links.raw_links).to be_blank
      end

      it "finds a link within markdown" do
        expect(one_link.raw_links).to eq(["http://www.imdb.com/name/nm2225369"])
      end

      it "can find two links from html" do
        expect(two_links.raw_links).to eq(["http://disneyland.disney.go.com/", "http://reddit.com"])
      end

      it "can find three links without markup" do
        expect(three_links.raw_links).to eq(["http://discourse.org", "http://discourse.org/another_url", "http://www.imdb.com/name/nm2225369"])
      end
    end

    describe "linked_hosts" do
      it "returns blank with no links" do
        expect(no_links.linked_hosts).to be_blank
      end

      it "returns the host and a count for links" do
        expect(two_links.linked_hosts).to eq("disneyland.disney.go.com" => 1, "reddit.com" => 1)
      end

      it "it counts properly with more than one link on the same host" do
        expect(three_links.linked_hosts).to eq("discourse.org" => 1, "www.imdb.com" => 1)
      end
    end

    describe "total host usage" do
      it "has none for a regular post" do
        expect(no_links.total_hosts_usage).to be_blank
      end

      context "with a previous host" do

        let(:another_disney_link) { post_with_body("[radiator springs](http://disneyland.disney.go.com/disney-california-adventure/radiator-springs-racers/)", newuser) }

        before do
          another_disney_link.save
          TopicLink.extract_from(another_disney_link)
        end

        it "contains the new post's links, PLUS the previous one" do
          expect(two_links.total_hosts_usage).to eq('disneyland.disney.go.com' => 2, 'reddit.com' => 1)
        end
      end
    end
  end

  describe "maximums" do
    fab!(:newuser) { Fabricate(:user, trust_level: TrustLevel[0]) }
    let(:post_one_link) { post_with_body("[sherlock](http://www.bbc.co.uk/programmes/b018ttws)", newuser) }
    let(:post_onebox) { post_with_body("http://www.google.com", newuser) }
    let(:post_code_link) { post_with_body("<code>http://www.google.com</code>", newuser) }
    let(:post_two_links) { post_with_body("<a href='http://discourse.org'>discourse</a> <a href='http://twitter.com'>twitter</a>", newuser) }
    let(:post_with_mentions) { post_with_body("hello @#{newuser.username} how are you doing?", newuser) }

    it "returns 0 links for an empty post" do
      expect(Fabricate.build(:post).link_count).to eq(0)
    end

    it "returns 0 links for a post with mentions" do
      expect(post_with_mentions.link_count).to eq(0)
    end

    it "finds links from markdown" do
      expect(post_one_link.link_count).to eq(1)
    end

    it "finds links from HTML" do
      expect(post_two_links.link_count).to eq(2)
    end

    context "with validation" do
      before do
        SiteSetting.newuser_max_links = 1
      end

      context 'with newuser' do
        it "returns true when within the amount of links allowed" do
          expect(post_one_link).to be_valid
        end

        it "doesn't allow more links than allowed" do
          expect(post_two_links).not_to be_valid
        end
      end

      it "allows multiple links for basic accounts" do
        post_two_links.user.trust_level = TrustLevel[1]
        expect(post_two_links).to be_valid
      end

      context "with min_trust_to_post_links" do
        it "considers oneboxes links" do
          SiteSetting.min_trust_to_post_links = 3
          post_onebox.user.trust_level = TrustLevel[2]
          expect(post_onebox).not_to be_valid
        end

        it "considers links within code" do
          SiteSetting.min_trust_to_post_links = 3
          post_onebox.user.trust_level = TrustLevel[2]
          expect(post_code_link).not_to be_valid
        end

        it "doesn't allow allow links if `min_trust_to_post_links` is not met" do
          SiteSetting.min_trust_to_post_links = 2
          post_two_links.user.trust_level = TrustLevel[1]
          expect(post_one_link).not_to be_valid
        end

        it "will skip the check for allowlisted domains" do
          SiteSetting.allowed_link_domains = 'www.bbc.co.uk'
          SiteSetting.min_trust_to_post_links = 2
          post_two_links.user.trust_level = TrustLevel[1]
          expect(post_one_link).to be_valid
        end
      end
    end
  end

  describe "@mentions" do
    context 'with raw_mentions' do
      it "returns an empty array with no matches" do
        post = Fabricate.build(:post, post_args.merge(raw: "Hello Jake and Finn!"))
        expect(post.raw_mentions).to eq([])
      end

      it "returns lowercase unique versions of the mentions" do
        post = Fabricate.build(:post, post_args.merge(raw: "@Jake @Finn @Jake"))
        expect(post.raw_mentions).to eq(['jake', 'finn'])
      end

      it "ignores pre" do
        # we need to force an inline
        post = Fabricate.build(:post, post_args.merge(raw: "p <pre>@Jake</pre> @Finn"))
        expect(post.raw_mentions).to eq(['finn'])
      end

      it "catches content between pre tags" do
        # per common mark we need to force an inline
        post = Fabricate.build(:post, post_args.merge(raw: "a <pre>hello</pre> @Finn <pre></pre>"))
        expect(post.raw_mentions).to eq(['finn'])
      end

      it "ignores code" do
        post = Fabricate.build(:post, post_args.merge(raw: "@Jake `@Finn`"))
        expect(post.raw_mentions).to eq(['jake'])
      end

      it "ignores quotes" do
        post = Fabricate.build(:post, post_args.merge(raw: "[quote=\"Evil Trout\"]\n@Jake\n[/quote]\n@Finn"))
        expect(post.raw_mentions).to eq(['finn'])
      end

      it "handles underscore in username" do
        post = Fabricate.build(:post, post_args.merge(raw: "@Jake @Finn @Jake_Old"))
        expect(post.raw_mentions).to eq(['jake', 'finn', 'jake_old'])
      end

      it "handles hyphen in groupname" do
        post = Fabricate.build(:post, post_args.merge(raw: "@org-board"))
        expect(post.raw_mentions).to eq(['org-board'])
      end
    end

    context "with max mentions" do
      fab!(:newuser) { Fabricate(:user, trust_level: TrustLevel[0]) }
      let(:post_with_one_mention) { post_with_body("@Jake is the person I'm mentioning", newuser) }
      let(:post_with_two_mentions) { post_with_body("@Jake @Finn are the people I'm mentioning", newuser) }

      context 'with new user' do
        before do
          SiteSetting.newuser_max_mentions_per_post = 1
          SiteSetting.max_mentions_per_post = 5
        end

        it "allows a new user to have newuser_max_mentions_per_post mentions" do
          expect(post_with_one_mention).to be_valid
        end

        it "doesn't allow a new user to have more than newuser_max_mentions_per_post mentions" do
          expect(post_with_two_mentions).not_to be_valid
        end
      end

      context "when not a new user" do
        before do
          SiteSetting.newuser_max_mentions_per_post = 0
          SiteSetting.max_mentions_per_post = 1
        end

        it "allows vmax_mentions_per_post mentions" do
          post_with_one_mention.user.trust_level = TrustLevel[1]
          expect(post_with_one_mention).to be_valid
        end

        it "doesn't allow to have more than max_mentions_per_post mentions" do
          post_with_two_mentions.user.trust_level = TrustLevel[1]
          expect(post_with_two_mentions).not_to be_valid
        end
      end
    end
  end

  describe 'validation' do
    it 'validates our default post' do
      expect(Fabricate.build(:post, post_args)).to be_valid
    end

    it 'create blank posts as invalid' do
      expect(Fabricate.build(:post, raw: "")).not_to be_valid
    end
  end

  describe "raw_hash" do
    let(:raw) { "this is our test post body" }
    let(:post) { post_with_body(raw) }

    it "returns a value" do
      expect(post.raw_hash).to be_present
    end

    it "returns blank for a nil body" do
      post.raw = nil
      expect(post.raw_hash).to be_blank
    end

    it "returns the same value for the same raw" do
      expect(post.raw_hash).to eq(post_with_body(raw).raw_hash)
    end

    it "returns a different value for a different raw" do
      expect(post.raw_hash).not_to eq(post_with_body("something else").raw_hash)
    end

    it "returns a different value with different text case" do
      expect(post.raw_hash).not_to eq(post_with_body("THIS is OUR TEST post BODy").raw_hash)
    end
  end

  describe 'revise' do
    let(:post) { Fabricate(:post, post_args) }
    let(:first_version_at) { post.last_version_at }

    it 'has no revision' do
      expect(post.revisions.size).to eq(0)
      expect(first_version_at).to be_present
      expect(post.revise(post.user, raw: post.raw)).to eq(false)
    end

    context 'with the same body' do
      it "doesn't change version" do
        expect { post.revise(post.user, raw: post.raw); post.reload }.not_to change(post, :version)
      end
    end

    context 'with grace period editing & edit windows' do
      before { SiteSetting.editing_grace_period = 1.minute.to_i }

      it 'works' do
        revised_at = post.updated_at + 2.minutes
        new_revised_at = revised_at + 2.minutes

        # grace period edit
        post.revise(post.user, { raw: 'updated body' }, revised_at: post.updated_at + 10.seconds)
        post.reload
        expect(post.version).to eq(1)
        expect(post.public_version).to eq(1)
        expect(post.revisions.size).to eq(0)
        expect(post.last_version_at.to_i).to eq(first_version_at.to_i)

        # revision much later
        post.revise(post.user, { raw: 'another updated body' }, revised_at: revised_at)
        post.reload
        expect(post.version).to eq(2)
        expect(post.public_version).to eq(2)
        expect(post.revisions.size).to eq(1)
        expect(post.last_version_at.to_i).to eq(revised_at.to_i)

        # new edit window
        post.revise(post.user, { raw: 'yet another updated body' }, revised_at: revised_at + 10.seconds)
        post.reload
        expect(post.version).to eq(2)
        expect(post.public_version).to eq(2)
        expect(post.revisions.size).to eq(1)
        expect(post.last_version_at.to_i).to eq(revised_at.to_i)

        # after second window
        post.revise(post.user, { raw: 'yet another, another updated body' }, revised_at: new_revised_at)
        post.reload
        expect(post.version).to eq(3)
        expect(post.public_version).to eq(3)
        expect(post.revisions.size).to eq(2)
        expect(post.last_version_at.to_i).to eq(new_revised_at.to_i)
      end
    end

    context 'with rate limiter' do
      let(:changed_by) { coding_horror }

      it "triggers a rate limiter" do
        EditRateLimiter.any_instance.expects(:performed!)
        post.revise(changed_by, raw: 'updated body')
      end
    end

    context 'with a new body' do
      let(:changed_by) { coding_horror }
      let!(:result) { post.revise(changed_by, raw: 'updated body') }

      it 'acts correctly' do
        expect(result).to eq(true)
        expect(post.raw).to eq('updated body')
        expect(post.invalidate_oneboxes).to eq(true)
        expect(post.version).to eq(2)
        expect(post.public_version).to eq(2)
        expect(post.revisions.size).to eq(1)
        expect(post.revisions.first.user).to be_present
      end

      context 'when second poster posts again quickly' do
        it 'is a grace period edit, because the second poster posted again quickly' do
          SiteSetting.editing_grace_period = 1.minute.to_i
          post.revise(changed_by, { raw: 'yet another updated body' }, revised_at: post.updated_at + 10.seconds)
          post.reload

          expect(post.version).to eq(2)
          expect(post.public_version).to eq(2)
          expect(post.revisions.size).to eq(1)
        end
      end
    end
  end

  describe 'before save' do
    let(:cooked) { "<p><div class=\"lightbox-wrapper\"><a data-download-href=\"//localhost:3000/#{upload_path}/34784374092783e2fef84b8bc96d9b54c11ceea0\" href=\"//localhost:3000/#{upload_path}/original/1X/34784374092783e2fef84b8bc96d9b54c11ceea0.gif\" class=\"lightbox\" title=\"Sword reworks.gif\"><img src=\"//localhost:3000/#{upload_path}/optimized/1X/34784374092783e2fef84b8bc96d9b54c11ceea0_1_690x276.gif\" width=\"690\" height=\"276\"><div class=\"meta\">\n<span class=\"filename\">Sword reworks.gif</span><span class=\"informations\">1000x400 1000 KB</span><span class=\"expand\"></span>\n</div></a></div></p>" }

    let(:post) do
      Fabricate(:post,
        raw: "<img src=\"/#{upload_path}/original/1X/34784374092783e2fef84b8bc96d9b54c11ceea0.gif\" width=\"690\" height=\"276\">",
        cooked: cooked
      )
    end

    it 'should not cook the post if raw has not been changed' do
      post.save!
      expect(post.cooked).to eq(cooked)
    end
  end

  describe 'after save' do
    let(:post) { Fabricate(:post, post_args) }

    it "has correct info set" do
      expect(post.user_deleted?).to eq(false)
      expect(post.post_number).to be_present
      expect(post.excerpt).to be_present
      expect(post.post_type).to eq(Post.types[:regular])
      expect(post.revisions).to be_blank
      expect(post.cooked).to be_present
      expect(post.external_id).to be_present
      expect(post.quote_count).to eq(0)
      expect(post.replies).to be_blank
    end

    context 'with extract_quoted_post_numbers' do
      let!(:post) { Fabricate(:post, post_args) }
      let(:reply) { Fabricate.build(:post, post_args) }

      it "finds the quote when in the same topic" do
        reply.raw = "[quote=\"EvilTrout, post:#{post.post_number}, topic:#{post.topic_id}\"]hello[/quote]"
        reply.extract_quoted_post_numbers
        expect(reply.quoted_post_numbers).to eq([post.post_number])
      end

      it "doesn't find the quote in a different topic" do
        reply.raw = "[quote=\"EvilTrout, post:#{post.post_number}, topic:#{post.topic_id + 1}\"]hello[/quote]"
        reply.extract_quoted_post_numbers
        expect(reply.quoted_post_numbers).to be_blank
      end

      it "doesn't find the quote in the same post" do
        reply = Fabricate.build(:post, post_args.merge(post_number: 646))
        reply.raw = "[quote=\"EvilTrout, post:#{reply.post_number}, topic:#{post.topic_id}\"]hello[/quote]"
        reply.extract_quoted_post_numbers
        expect(reply.quoted_post_numbers).to be_blank
      end
    end

    context 'with a new reply' do
      fab!(:topic) { Fabricate(:topic) }
      let(:other_user) { coding_horror }
      let(:reply_text) { "[quote=\"Evil Trout, post:1\"]\nhello\n[/quote]\nHmmm!" }
      let!(:post) { PostCreator.new(topic.user, raw: Fabricate.build(:post).raw, topic_id: topic.id).create }
      let!(:reply) { PostCreator.new(other_user, raw: reply_text, topic_id: topic.id, reply_to_post_number: post.post_number).create }

      it 'has a quote' do
        expect(reply.quote_count).to eq(1)
      end

      it 'has a reply to the user of the original user' do
        expect(reply.reply_to_user).to eq(post.user)
      end

      it 'increases the reply count of the parent' do
        post.reload
        expect(post.reply_count).to eq(1)
      end

      it 'increases the reply count of the topic' do
        topic.reload
        expect(topic.reply_count).to eq(1)
      end

      it 'is the child of the parent post' do
        expect(post.replies).to eq([reply])
      end

      it "doesn't change the post count when you edit the reply" do
        reply.raw = 'updated raw'
        reply.save
        post.reload
        expect(post.reply_count).to eq(1)
      end

      context 'with a multi-quote reply' do
        let!(:multi_reply) do
          raw = "[quote=\"Evil Trout, post:1\"]post1 quote[/quote]\nAha!\n[quote=\"Evil Trout, post:2\"]post2 quote[/quote]\nNeat-o"
          PostCreator.new(other_user, raw: raw, topic_id: topic.id, reply_to_post_number: post.post_number).create
        end

        it 'has the correct info set' do
          expect(multi_reply.quote_count).to eq(2)
          expect(post.replies.include?(multi_reply)).to eq(true)
          expect(reply.replies.include?(multi_reply)).to eq(true)
        end
      end
    end
  end

  describe 'summary' do
    let!(:p1) { Fabricate(:post, post_args.merge(score: 4, percent_rank: 0.33)) }
    let!(:p2) { Fabricate(:post, post_args.merge(score: 10, percent_rank: 0.66)) }
    let!(:p3) { Fabricate(:post, post_args.merge(score: 5, percent_rank: 0.99)) }
    fab!(:p4) { Fabricate(:post, percent_rank: 0.99) }

    it "returns the OP and posts above the threshold in summary mode" do
      SiteSetting.summary_percent_filter = 66
      expect(Post.summary(topic.id).order(:post_number)).to eq([p1, p2])
      expect(Post.summary(p4.topic.id)).to eq([p4])
    end
  end

  describe 'sort_order' do
    context 'with a regular topic' do
      let!(:p1) { Fabricate(:post, post_args) }
      let!(:p2) { Fabricate(:post, post_args) }
      let!(:p3) { Fabricate(:post, post_args) }

      it 'defaults to created order' do
        expect(Post.regular_order).to eq([p1, p2, p3])
      end
    end
  end

  describe "reply_history" do
    let!(:p1) { Fabricate(:post, post_args) }
    let!(:p2) { Fabricate(:post, post_args.merge(reply_to_post_number: p1.post_number)) }
    let!(:p3) { Fabricate(:post, post_args) }
    let!(:p4) { Fabricate(:post, post_args.merge(reply_to_post_number: p2.post_number)) }

    it "returns the posts in reply to this post" do
      expect(p4.reply_history).to eq([p1, p2])
      expect(p4.reply_history(1)).to eq([p2])
      expect(p3.reply_history).to be_blank
      expect(p2.reply_history).to eq([p1])
    end

  end

  describe "reply_ids" do
    fab!(:topic) { Fabricate(:topic) }
    let!(:p1) { Fabricate(:post, topic: topic, post_number: 1) }
    let!(:p2) { Fabricate(:post, topic: topic, post_number: 2, reply_to_post_number: 1) }
    let!(:p3) { Fabricate(:post, topic: topic, post_number: 3) }
    let!(:p4) { Fabricate(:post, topic: topic, post_number: 4, reply_to_post_number: 2) }
    let!(:p5) { Fabricate(:post, topic: topic, post_number: 5, reply_to_post_number: 4) }
    let!(:p6) { Fabricate(:post, topic: topic, post_number: 6) }

    before {
      PostReply.create!(post: p1, reply: p2)
      PostReply.create!(post: p2, reply: p4)
      PostReply.create!(post: p2, reply: p6) # simulates p6 quoting p2
      PostReply.create!(post: p3, reply: p5) # simulates p5 quoting p3
      PostReply.create!(post: p4, reply: p5)
      PostReply.create!(post: p6, reply: p6) # https://meta.discourse.org/t/topic-quoting-itself-displays-reply-indicator/76085
    }

    it "returns the reply ids and their level" do
      expect(p1.reply_ids).to eq([{ id: p2.id, level: 1 }, { id: p4.id, level: 2 }, { id: p6.id, level: 2 }])
      expect(p2.reply_ids).to eq([{ id: p4.id, level: 1 }, { id: p6.id, level: 1 }])
      expect(p3.reply_ids).to be_empty # has no replies
      expect(p4.reply_ids).to be_empty # p5 replies to 2 posts (p4 and p3)
      expect(p5.reply_ids).to be_empty # has no replies
      expect(p6.reply_ids).to be_empty # quotes itself
    end

    it "ignores posts moved to other topics" do
      p2.update_column(:topic_id, Fabricate(:topic).id)
      expect(p1.reply_ids).to be_blank
    end

    it "doesn't include the same reply twice" do
      PostReply.create!(post: p4, reply: p1)
      expect(p1.reply_ids.size).to eq(4)
    end

    it "does not skip any replies" do
      expect(p1.reply_ids(only_replies_to_single_post: false)).to eq([{ id: p2.id, level: 1 }, { id: p4.id, level: 2 }, { id: p5.id, level: 3 }, { id: p6.id, level: 2 }])
      expect(p2.reply_ids(only_replies_to_single_post: false)).to eq([{ id: p4.id, level: 1 }, { id: p5.id, level: 2 }, { id: p6.id, level: 1 }])
      expect(p3.reply_ids(only_replies_to_single_post: false)).to eq([{ id: p5.id, level: 1 }])
      expect(p4.reply_ids(only_replies_to_single_post: false)).to eq([{ id: p5.id, level: 1 }])
      expect(p5.reply_ids(only_replies_to_single_post: false)).to be_empty # has no replies
      expect(p6.reply_ids(only_replies_to_single_post: false)).to be_empty # quotes itself
    end
  end

  describe 'urls' do
    it 'no-ops for empty list' do
      expect(Post.urls([])).to eq({})
    end

    # integration test -> should move to centralized integration test
    it 'finds urls for posts presented' do
      p1 = Fabricate(:post)
      p2 = Fabricate(:post)
      expect(Post.urls([p1.id, p2.id])).to eq(p1.id => p1.url, p2.id => p2.url)
    end
  end

  describe "details" do
    it "adds details" do
      post = Fabricate.build(:post)
      post.add_detail("key", "value")
      expect(post.post_details.size).to eq(1)
      expect(post.post_details.first.key).to eq("key")
      expect(post.post_details.first.value).to eq("value")
    end

    it "can find a post by a detail" do
      detail = Fabricate(:post_detail)
      post   = detail.post
      expect(Post.find_by_detail(detail.key, detail.value).id).to eq(post.id)
    end
  end

  describe "cooking" do
    let(:post) { Fabricate.build(:post, post_args.merge(raw: "please read my blog http://blog.example.com")) }

    it "should unconditionally follow links for staff" do

      SiteSetting.tl3_links_no_follow = true
      post.user.trust_level = 1
      post.user.moderator = true
      post.save

      expect(post.cooked).not_to match(/nofollow/)
    end

    it "should add nofollow to links in the post for trust levels below 3" do
      post.user.trust_level = 2
      post.save
      expect(post.cooked).to match(/noopener nofollow ugc/)
    end

    it "when tl3_links_no_follow is false, should not add nofollow for trust level 3 and higher" do
      SiteSetting.tl3_links_no_follow = false
      post.user.trust_level = 3
      post.save
      expect(post.cooked).not_to match(/nofollow/)
    end

    it "when tl3_links_no_follow is true, should add nofollow for trust level 3 and higher" do
      SiteSetting.tl3_links_no_follow = true
      post.user.trust_level = 3
      post.save
      expect(post.cooked).to match(/noopener nofollow ugc/)
    end

    it "passes the last_editor_id as the markdown user_id option" do
      post.save
      post.reload
      PostAnalyzer.any_instance.expects(:cook).with(
        post.raw, { cook_method: Post.cook_methods[:regular], user_id: post.last_editor_id }
      )
      post.cook(post.raw)
      user_editor = Fabricate(:user)
      post.update!(last_editor_id: user_editor.id)
      PostAnalyzer.any_instance.expects(:cook).with(
        post.raw, { cook_method: Post.cook_methods[:regular], user_id: user_editor.id }
      )
      post.cook(post.raw)
    end

    describe 'mentions' do
      fab!(:group) do
        Fabricate(:group,
          visibility_level: Group.visibility_levels[:members],
          mentionable_level: Group::ALIAS_LEVELS[:members_mods_and_admins]
        )
      end

      before do
        Jobs.run_immediately!
      end

      describe 'when user can not mention a group' do
        it "should not create the mention with the notify class" do
          post = Fabricate(:post, raw: "hello @#{group.name}")
          post.trigger_post_process
          post.reload

          expect(post.cooked).to eq(
            %Q|<p>hello <a class="mention-group" href="/groups/#{group.name}">@#{group.name}</a></p>|
          )
        end
      end

      describe 'when user can mention a group' do
        before do
          group.add(post.user)
        end

        it 'should create the mention' do
          post.update!(raw: "hello @#{group.name}")
          post.trigger_post_process
          post.reload

          expect(post.cooked).to eq(
            %Q|<p>hello <a class="mention-group notify" href="/groups/#{group.name}">@#{group.name}</a></p>|
          )
        end
      end

      describe 'when group owner can mention a group' do
        before do
          group.update!(mentionable_level: Group::ALIAS_LEVELS[:owners_mods_and_admins])
          group.add_owner(post.user)
        end

        it 'should create the mention' do
          post.update!(raw: "hello @#{group.name}")
          post.trigger_post_process
          post.reload

          expect(post.cooked).to eq(
            %Q|<p>hello <a class="mention-group notify" href="/groups/#{group.name}">@#{group.name}</a></p>|
          )
        end
      end
    end
  end

  describe "has_host_spam" do
    let(:raw) { "hello from my site http://www.example.net http://#{GlobalSetting.hostname} http://#{RailsMultisite::ConnectionManagement.current_hostname}" }

    it "correctly detects host spam" do
      post = Fabricate(:post, raw: raw)

      expect(post.total_hosts_usage).to eq("www.example.net" => 1)
      post.acting_user.trust_level = 0

      expect(post.has_host_spam?).to eq(false)

      SiteSetting.newuser_spam_host_threshold = 1

      expect(post.has_host_spam?).to eq(true)

      SiteSetting.allowed_spam_host_domains = "bla.com|boo.com | example.net "
      expect(post.has_host_spam?).to eq(false)
    end

    it "doesn't punish staged users" do
      SiteSetting.newuser_spam_host_threshold = 1
      user = Fabricate(:user, staged: true, trust_level: 0)
      post = Fabricate(:post, raw: raw, user: user)
      expect(post.has_host_spam?).to eq(false)
    end

    it "punishes previously staged users that were created within 1 day" do
      SiteSetting.newuser_spam_host_threshold = 1
      SiteSetting.newuser_max_links = 3
      user = Fabricate(:user, staged: true, trust_level: 0)
      user.created_at = 1.hour.ago
      user.unstage!
      post = Fabricate(:post, raw: raw, user: user)
      expect(post.has_host_spam?).to eq(true)
    end

    it "doesn't punish previously staged users over 1 day old" do
      SiteSetting.newuser_spam_host_threshold = 1
      SiteSetting.newuser_max_links = 3
      user = Fabricate(:user, staged: true, trust_level: 0)
      user.created_at = 2.days.ago
      user.unstage!
      post = Fabricate(:post, raw: raw, user: user)
      expect(post.has_host_spam?).to eq(false)
    end

    it "ignores private messages" do
      SiteSetting.newuser_spam_host_threshold = 1
      user = Fabricate(:user, trust_level: 0)
      post = Fabricate(:post, raw: raw, user: user, topic: Fabricate(:private_message_topic, user: user))
      expect(post.has_host_spam?).to eq(false)
    end
  end

  it "has custom fields" do
    post = Fabricate(:post)
    expect(post.custom_fields["a"]).to eq(nil)

    post.custom_fields["Tommy"] = "Hanks"
    post.custom_fields["Vincent"] = "Vega"
    post.save

    post = Post.find(post.id)
    expect(post.custom_fields).to eq("Tommy" => "Hanks", "Vincent" => "Vega")
  end

  describe "#excerpt_for_topic" do
    it "returns a topic excerpt, defaulting to 220 chars" do
      expected_excerpt = "This is a sample post with semi-long raw content. The raw content is also more than \ntwo hundred characters to satisfy any test conditions that require content longer \nthan the typical test post raw content. It really is&hellip;"
      post = Fabricate(:post_with_long_raw_content)
      post.rebake!
      excerpt = post.excerpt_for_topic
      expect(excerpt).to eq(expected_excerpt)
    end

    it "respects the site setting for topic excerpt" do
      SiteSetting.topic_excerpt_maxlength = 10
      expected_excerpt = "This is a &hellip;"
      post = Fabricate(:post_with_long_raw_content)
      post.rebake!
      excerpt = post.excerpt_for_topic
      expect(excerpt).to eq(expected_excerpt)
    end
  end

  describe "#rebake!" do
    it "will rebake a post correctly" do
      post = create_post
      expect(post.baked_at).not_to eq(nil)
      first_baked = post.baked_at
      first_cooked = post.cooked

      DB.exec("UPDATE posts SET cooked = 'frogs' WHERE id = ?", [ post.id ])
      post.reload

      post.expects(:publish_change_to_clients!).with(:rebaked)

      result = post.rebake!

      expect(post.baked_at).not_to eq_time(first_baked)
      expect(post.cooked).to eq(first_cooked)
      expect(result).to eq(true)
    end

    it "updates the topic excerpt at the same time if it is the OP" do
      post = create_post
      post.topic.update(excerpt: "test")
      DB.exec("UPDATE posts SET cooked = 'frogs' WHERE id = ?", [ post.id ])
      post.reload
      result = post.rebake!
      post.topic.reload
      expect(post.topic.excerpt).not_to eq("test")
    end

    it "does not update the topic excerpt if the post is not the OP" do
      post = create_post
      post2 = create_post
      post.topic.update(excerpt: "test")
      result = post2.rebake!
      post.topic.reload
      expect(post.topic.excerpt).to eq("test")
    end

    it "works with posts in deleted topics" do
      post = create_post
      post.topic.trash!
      post.reload
      post.rebake!
    end

    it "uses inline onebox cache by default" do
      Jobs.run_immediately!
      stub_request(:get, "http://testonebox.com/vvf").to_return(status: 200, body: <<~HTML)
        <html><head>
          <title>hello this is Testonebox!</title>
        </head></html>
      HTML
      post = create_post(raw: <<~POST).reload
        hello inline onebox http://testonebox.com/vvf
      POST
      expect(post.cooked).to include("hello this is Testonebox!")

      stub_request(:get, "http://testonebox.com/vvf").to_return(status: 200, body: <<~HTML)
        <html><head>
          <title>hello this is updated Testonebox!</title>
        </head></html>
      HTML
      post.rebake!
      expect(post.reload.cooked).to include("hello this is Testonebox!")
    ensure
      InlineOneboxer.invalidate("http://testonebox.com/vvf")
    end

    it "passing invalidate_oneboxes: true ignores inline onebox cache" do
      Jobs.run_immediately!
      stub_request(:get, "http://testonebox.com/vvf22").to_return(status: 200, body: <<~HTML)
        <html><head>
          <title>hello this is Testonebox!</title>
        </head></html>
      HTML
      post = create_post(raw: <<~POST).reload
        hello inline onebox http://testonebox.com/vvf22
      POST
      expect(post.cooked).to include("hello this is Testonebox!")

      stub_request(:get, "http://testonebox.com/vvf22").to_return(status: 200, body: <<~HTML)
        <html><head>
          <title>hello this is updated Testonebox!</title>
        </head></html>
      HTML
      post.rebake!(invalidate_oneboxes: true)
      expect(post.reload.cooked).to include("hello this is updated Testonebox!")
    ensure
      InlineOneboxer.invalidate("http://testonebox.com/vvf22")
    end
  end

  describe "#set_owner" do
    fab!(:post) { Fabricate(:post) }

    it "will change owner of a post correctly" do
      post.set_owner(coding_horror, Discourse.system_user)
      post.reload

      expect(post.user).to eq(coding_horror)
      expect(post.revisions.size).to eq(1)
    end

    it "skips creating new post revision if skip_revision is true" do
      post.set_owner(coding_horror, Discourse.system_user, true)
      post.reload

      expect(post.user).to eq(coding_horror)
      expect(post.revisions.size).to eq(0)
    end

    it "uses default locale for edit reason" do
      I18n.locale = 'de'

      post.set_owner(coding_horror, Discourse.system_user)
      post.reload

      expected_reason = I18n.with_locale(SiteSetting.default_locale) do
        I18n.t('change_owner.post_revision_text')
      end

      expect(post.edit_reason).to eq(expected_reason)
    end
  end

  describe ".rebake_old" do
    it "will catch posts it needs to rebake" do
      post = create_post
      post.update_columns(baked_at: Time.new(2000, 1, 1), baked_version: -1)
      Post.rebake_old(100)

      post.reload
      expect(post.baked_at).to be > 1.day.ago

      baked = post.baked_at
      Post.rebake_old(100)
      post.reload
      expect(post.baked_at).to eq_time(baked)
    end

    it "will rate limit globally" do

      post1 = create_post
      post2 = create_post
      post3 = create_post

      Post.where(id: [post1.id, post2.id, post3.id]).update_all(baked_version: -1)

      global_setting :max_old_rebakes_per_15_minutes, 2

      RateLimiter.clear_all_global!
      RateLimiter.enable

      Post.rebake_old(100)

      expect(post3.reload.baked_version).not_to eq(-1)
      expect(post2.reload.baked_version).not_to eq(-1)
      expect(post1.reload.baked_version).to eq(-1)

    end
  end

  describe "#hide!" do
    fab!(:post) { Fabricate(:post) }

    after do
      Discourse.redis.flushdb
    end

    it "should ignore the unique post validator when hiding a post with similar content as a recent post" do
      post_2 = Fabricate(:post, user: post.user)
      SiteSetting.unique_posts_mins = 10
      post.store_unique_post_key

      expect(post_2.valid?).to eq(false)
      expect(post_2.errors.full_messages.to_s).to include(I18n.t(:just_posted_that))

      post_2.hide!(PostActionType.types[:off_topic])

      expect(post_2.reload.hidden).to eq(true)
    end

    it 'should decrease user_stat topic_count for first post' do
      expect do
        post.hide!(PostActionType.types[:off_topic])
      end.to change { post.user.user_stat.reload.topic_count }.from(1).to(0)
    end

    it 'should decrease user_stat post_count' do
      post_2 = Fabricate(:post, topic: post.topic, user: post.user)

      expect do
        post_2.hide!(PostActionType.types[:off_topic])
      end.to change { post_2.user.user_stat.reload.post_count }.from(1).to(0)
    end
  end

  describe "#unhide!" do
    fab!(:post) { Fabricate(:post) }

    before { SiteSetting.unique_posts_mins = 5 }

    it "will unhide the first post & make the topic visible" do
      hidden_topic = Fabricate(:topic, visible: false)

      post = create_post(topic: hidden_topic)
      post.update_columns(hidden: true, hidden_at: Time.now, hidden_reason_id: 1)
      post.reload

      expect(post.hidden).to eq(true)

      post.expects(:publish_change_to_clients!).with(:acted)

      post.unhide!

      post.reload
      hidden_topic.reload

      expect(post.hidden).to eq(false)
      expect(hidden_topic.visible).to eq(true)
    end

    it 'should increase user_stat topic_count for first post' do
      post.hide!(PostActionType.types[:off_topic])

      expect do
        post.unhide!
      end.to change { post.user.user_stat.reload.topic_count }.from(0).to(1)
    end

    it 'should decrease user_stat post_count' do
      post_2 = Fabricate(:post, topic: post.topic, user: post.user)
      post_2.hide!(PostActionType.types[:off_topic])

      expect do
        post_2.unhide!
      end.to change { post_2.user.user_stat.reload.post_count }.from(0).to(1)
    end
  end

  it "will unhide the post but will keep the topic invisible/unlisted" do
    hidden_topic = Fabricate(:topic, visible: false)
    create_post(topic: hidden_topic)
    second_post = create_post(topic: hidden_topic)

    second_post.update_columns(hidden: true, hidden_at: Time.now, hidden_reason_id: 1)
    second_post.expects(:publish_change_to_clients!).with(:acted)

    second_post.unhide!

    second_post.reload
    hidden_topic.reload

    expect(second_post.hidden).to eq(false)
    expect(hidden_topic.visible).to eq(false)
  end

  it "automatically orders post revisions by number ascending" do
    post = Fabricate(:post)
    post.revisions.create!(user_id: 1, post_id: post.id, number: 2)
    post.revisions.create!(user_id: 1, post_id: post.id, number: 1)
    expect(post.revisions.pluck(:number)).to eq([1, 2])
  end

  describe 'uploads' do
    fab!(:video_upload) { Fabricate(:upload, extension: "mp4") }
    fab!(:image_upload) { Fabricate(:upload) }
    fab!(:audio_upload) { Fabricate(:upload, extension: "ogg") }
    fab!(:attachment_upload) { Fabricate(:upload, extension: "csv") }
    fab!(:attachment_upload_2) { Fabricate(:upload) }
    fab!(:attachment_upload_3) { Fabricate(:upload, extension: nil) }

    let(:base_url) { "#{Discourse.base_url_no_prefix}#{Discourse.base_path}" }
    let(:video_url) { "#{base_url}#{video_upload.url}" }
    let(:audio_url) { "#{base_url}#{audio_upload.url}" }

    let(:raw_multiple) do
      <<~RAW
      <a href="#{attachment_upload.url}">Link</a>
      [test|attachment](#{attachment_upload_2.short_url})
      [test3|attachment](#{attachment_upload_3.short_url})
      <img src="#{image_upload.url}">

      <video width="100%" height="100%" controls>
        <source src="#{video_url}">
        <a href="#{video_url}">#{video_url}</a>
      </video>

      <audio controls>
        <source src="#{audio_url}">
        <a href="#{audio_url}">#{audio_url}</a>
      </audio>
      RAW
    end

    let(:post) { Fabricate(:post, raw: raw_multiple) }

    it "removes post uploads on destroy" do
      post.link_post_uploads

      post.trash!
      expect(UploadReference.count).to eq(6)

      post.destroy!
      expect(UploadReference.count).to eq(0)
    end

    describe "#link_post_uploads" do
      it "finds all the uploads in the post" do
        post.link_post_uploads

        expect(UploadReference.where(target: post).pluck(:upload_id)).to contain_exactly(
          video_upload.id,
          image_upload.id,
          audio_upload.id,
          attachment_upload.id,
          attachment_upload_2.id,
          attachment_upload_3.id
        )
      end

      it "cleans the reverse index up for the current post" do
        post.link_post_uploads

        post_uploads_ids = post.upload_references.pluck(:id)

        post.link_post_uploads

        expect(post.reload.upload_references.pluck(:id)).to_not contain_exactly(post_uploads_ids)
      end

      context "when secure uploads is enabled" do
        before do
          setup_s3
        SiteSetting.authorized_extensions = "pdf|png|jpg|csv"
        SiteSetting.secure_uploads = true
        end

        it "sets the access_control_post_id on uploads in the post that don't already have the value set" do
          other_post = Fabricate(:post)
          video_upload.update(access_control_post_id: other_post.id)
          audio_upload.update(access_control_post_id: other_post.id)

          post.link_post_uploads

          image_upload.reload
          video_upload.reload
          expect(image_upload.access_control_post_id).to eq(post.id)
          expect(video_upload.access_control_post_id).not_to eq(post.id)
        end

        context "for custom emoji" do
          before do
            CustomEmoji.create(name: "meme", upload: image_upload)
          end
          it "never sets an access control post because they should not be secure" do
            post.link_post_uploads
            expect(image_upload.reload.access_control_post_id).to eq(nil)
          end
        end
      end
    end

    describe '#update_uploads_secure_status' do
      fab!(:user) { Fabricate(:user, trust_level: 0) }

      let(:raw) do
        <<~RAW
        <a href="#{attachment_upload.url}">Link</a>
        <img src="#{image_upload.url}">
        RAW
      end

      before do
        Jobs.run_immediately!

        setup_s3
        SiteSetting.authorized_extensions = "pdf|png|jpg|csv"
        SiteSetting.secure_uploads = true

        attachment_upload.update!(original_filename: "hello.csv")

        stub_upload(attachment_upload)
        stub_upload(image_upload)
      end

      it "marks image and attachment uploads as secure in PMs when secure_uploads is ON" do
        SiteSetting.secure_uploads = true
        post = Fabricate(:post, raw: raw, user: user, topic: Fabricate(:private_message_topic, user: user))
        post.link_post_uploads
        post.update_uploads_secure_status(source: "test")

        expect(UploadReference.where(target: post).joins(:upload).pluck(:upload_id, :secure)).to contain_exactly(
          [attachment_upload.id, true],
          [image_upload.id, true]
        )
      end

      it "marks image uploads as not secure in PMs when when secure_uploads is ON" do
        SiteSetting.secure_uploads = false
        post = Fabricate(:post, raw: raw, user: user, topic: Fabricate(:private_message_topic, user: user))
        post.link_post_uploads
        post.update_uploads_secure_status(source: "test")

        expect(UploadReference.where(target: post).joins(:upload).pluck(:upload_id, :secure)).to contain_exactly(
          [attachment_upload.id, false],
          [image_upload.id, false]
        )
      end

      it "marks attachments as secure when relevant setting is enabled" do
        SiteSetting.secure_uploads = true
        private_category = Fabricate(:private_category, group: Fabricate(:group))
        post = Fabricate(:post, raw: raw, user: user, topic: Fabricate(:topic, user: user, category: private_category))
        post.link_post_uploads
        post.update_uploads_secure_status(source: "test")

        expect(UploadReference.where(target: post).joins(:upload).pluck(:upload_id, :secure)).to contain_exactly(
          [attachment_upload.id, true],
          [image_upload.id, true]
        )
      end

      it "does not mark an upload as secure if it has already been used in a public topic" do
        post = Fabricate(:post, raw: raw, user: user, topic: Fabricate(:topic, user: user))
        post.link_post_uploads
        post.update_uploads_secure_status(source: "test")

        pm = Fabricate(:post, raw: raw, user: user, topic: Fabricate(:private_message_topic, user: user))
        pm.link_post_uploads
        pm.update_uploads_secure_status(source: "test")

        expect(UploadReference.where(target: pm).joins(:upload).pluck(:upload_id, :secure)).to contain_exactly(
          [attachment_upload.id, false],
          [image_upload.id, false]
        )
      end
    end
  end

  describe 'topic updated_at' do
    let :topic do
      create_post.topic
    end

    def updates_topic_updated_at
      time = freeze_time 1.day.from_now
      result = yield

      topic.reload
      expect(topic.updated_at).to eq_time(time)

      result
    end

    it "will update topic updated_at for all topic related events" do
      SiteSetting.whispers_allowed_groups = "#{Group::AUTO_GROUPS[:staff]}"

      post = updates_topic_updated_at do
        create_post(topic_id: topic.id, post_type: Post.types[:whisper])
      end

      updates_topic_updated_at do
        PostDestroyer.new(Discourse.system_user, post).destroy
      end

      updates_topic_updated_at do
        PostDestroyer.new(Discourse.system_user, post).recover
      end

    end
  end

  describe "have_uploads" do
    it "should find all posts with the upload" do
      ids = []
      ids << Fabricate(:post, cooked: "A post with upload <img src='/#{upload_path}/1/defghijklmno.png'>").id
      ids << Fabricate(:post, cooked: "A post with optimized image <img src='/#{upload_path}/_optimized/601/961/defghijklmno.png'>").id
      Fabricate(:post)
      ids << Fabricate(:post, cooked: "A post with upload <img src='/#{upload_path}/original/1X/abc/defghijklmno.png'>").id
      ids << Fabricate(:post, cooked: "A post with upload link <a href='https://cdn.example.com/original/1X/abc/defghijklmno.png'>").id
      ids << Fabricate(:post, cooked: "A post with optimized image <img src='https://cdn.example.com/bucket/optimized/1X/abc/defghijklmno.png'>").id
      Fabricate(:post, cooked: "A post with external link <a href='https://example.com/wp-content/uploads/abcdef.gif'>")
      ids << Fabricate(:post, cooked: 'A post with missing upload <img src="https://cdn.example.com/images/transparent.png" data-orig-src="upload://defghijklmno.png">').id
      ids << Fabricate(:post, cooked: 'A post with video upload <video width="100%" height="100%" controls=""><source src="https://cdn.example.com/uploads/short-url/XefghijklmU9.mp4"><a href="https://cdn.example.com/uploads/short-url/XefghijklmU9.mp4">https://cdn.example.com/uploads/short-url/XefghijklmU9.mp4</a></video>').id
      expect(Post.have_uploads.order(:id).pluck(:id)).to eq(ids)
    end
  end

  describe '#each_upload_url' do
    it "correctly identifies all upload urls" do
      SiteSetting.authorized_extensions = "*"
      upload1 = Fabricate(:upload)
      upload2 = Fabricate(:upload)
      upload3 = Fabricate(:video_upload)
      upload4 = Fabricate(:upload)
      upload5 = Fabricate(:upload)
      upload6 = Fabricate(:video_upload)
      upload7 = Fabricate(:upload, extension: "vtt")

      set_cdn_url "https://awesome.com/somepath"

      post = Fabricate(:post, raw: <<~RAW)
      A post with image, video and link upload.

      ![](#{upload1.short_url})

      "#{GlobalSetting.cdn_url}#{upload4.url}"

      <a href='#{Discourse.base_url}#{upload2.url}'>Link to upload</a>
      ![](http://example.com/external.png)

      #{Discourse.base_url}#{upload3.short_path}

      <video poster="#{Discourse.base_url}#{upload5.url}">
        <source src="#{Discourse.base_url}#{upload6.url}" type="video/mp4" />
        <track src="#{Discourse.base_url}#{upload7.url}" label="English" kind="subtitles" srclang="en" default />
      </video>
      RAW

      urls = []
      paths = []

      post.each_upload_url do |src, path, _|
        urls << src
        paths << path
      end

      expect(urls).to contain_exactly(
        "#{GlobalSetting.cdn_url}#{upload1.url}",
        "#{GlobalSetting.cdn_url}#{upload4.url}",
        "#{Discourse.base_url}#{upload2.url}",
        "#{Discourse.base_url}#{upload3.short_path}",
        "#{Discourse.base_url}#{upload5.url}",
        "#{Discourse.base_url}#{upload6.url}",
        "#{Discourse.base_url}#{upload7.url}"
      )

      expect(paths).to contain_exactly(
        upload1.url,
        upload4.url,
        upload2.url,
        nil,
        upload5.url,
        upload6.url,
        upload7.url
      )
    end

    it "correctly identifies secure uploads" do
      setup_s3
      SiteSetting.authorized_extensions = "pdf|png|jpg|csv"
      SiteSetting.secure_uploads = true

      upload1 = Fabricate(:upload_s3, secure: true)
      upload2 = Fabricate(:upload_s3, secure: true)

      # Test including domain:
      upload1_url = UrlHelper.cook_url(upload1.url, secure: true)
      # Test without domain:
      upload2_path = URI.parse(UrlHelper.cook_url(upload2.url, secure: true)).path

      post = Fabricate(:post, raw: <<~RAW)
       <img src="#{upload1_url}"/>
       <img src="#{upload2_path}"/>
      RAW

      sha1s = []

      post.each_upload_url do |src, path, sha|
        sha1s << sha
      end

      expect(sha1s).to contain_exactly(upload1.sha1, upload2.sha1)
    end

    it "correctly identifies missing uploads with short url" do
      upload = Fabricate(:upload)
      url = upload.short_url
      sha1 = upload.sha1
      upload.destroy!

      post = Fabricate(:post, raw: "![upload](#{url})")

      urls = []
      paths = []
      sha1s = []

      post.each_upload_url do |src, path, sha|
        urls << src
        paths << path
        sha1s << sha
      end

      expect(urls).to contain_exactly(url)
      expect(paths).to contain_exactly(nil)
      expect(sha1s).to contain_exactly(sha1)
    end

    it "should skip external urls with upload url in query string" do
      setup_s3

      urls = []
      upload = Fabricate(:upload_s3)
      post = Fabricate(:post, raw: "<a href='https://link.example.com/redirect?url=#{Discourse.store.cdn_url(upload.url)}'>Link to upload</a>")
      post.each_upload_url { |src, _, _| urls << src }
      expect(urls).to be_empty
    end

    it "skip S3 cdn urls with different path" do
      setup_s3
      SiteSetting.Upload.stubs(:s3_cdn_url).returns("https://cdn.example.com/site1")

      urls = []
      raw = "<img src='https://cdn.example.com/site1/original/1X/bc68acbc8c022726e69f980e00d6811212r.jpg' /><img src='https://cdn.example.com/site2/original/1X/bc68acbc8c022726e69f980e00d68112128.jpg' />"
      post = Fabricate(:post, raw: raw)
      post.each_upload_url { |src, _, _| urls << src }
      expect(urls).to contain_exactly("https://cdn.example.com/site1/original/1X/bc68acbc8c022726e69f980e00d6811212r.jpg")
    end
  end

  describe "#publish_changes_to_client!" do
    fab!(:user1) { Fabricate(:user) }
    fab!(:user3) { Fabricate(:user) }
    fab!(:topic) { Fabricate(:private_message_topic, user: user1) }
    fab!(:post) { Fabricate(:post, topic: topic) }
    fab!(:group_user) { Fabricate(:group_user, user: user3) }
    fab!(:topic_allowed_group) { Fabricate(:topic_allowed_group, topic: topic, group: group_user.group) }
    let(:user2) { topic.allowed_users.last }

    it 'send message to all users participating in private conversation' do
      freeze_time
      message = {
        id: post.id,
        post_number: post.post_number,
        updated_at: Time.now,
        user_id: post.user_id,
        last_editor_id: post.last_editor_id,
        type: :created,
        version: post.version
      }

      messages = MessageBus.track_publish("/topic/#{topic.id}") do
        post.publish_change_to_clients!(:created)
      end

      created_message = messages.select { |msg| msg.data[:type] == :created }.first
      expect(created_message).to be_present
      expect(created_message.data).to eq(message)
      expect(created_message.user_ids.sort).to eq([user1.id, user2.id, user3.id].sort)

      stats_message = messages.select { |msg| msg.data[:type] == :created }.first
      expect(stats_message).to be_present
      expect(stats_message.user_ids.sort).to eq([user1.id, user2.id, user3.id].sort)
    end

    it 'also publishes topic stats' do
      messages = MessageBus.track_publish("/topic/#{topic.id}") do
        post.publish_change_to_clients!(:created)
      end

      stats_message = messages.select { |msg| msg.data[:type] == :stats }.first
      expect(stats_message).to be_present
    end

    it 'skips publishing topic stats when requested' do
      messages = MessageBus.track_publish("/topic/#{topic.id}") do
        post.publish_change_to_clients!(:anything, { skip_topic_stats: true })
      end

      stats_message = messages.select { |msg| msg.data[:type] == :stats }.first
      expect(stats_message).to be_blank

      # ensure that :skip_topic_stats did not get merged with the message
      other_message = messages.select { |msg| msg.data[:type] == :anything }.first
      expect(other_message).to be_present
      expect(other_message.data.key?(:skip_topic_stats)).to be_falsey
    end
  end

  describe "#cannot_permanently_delete_reason" do
    fab!(:post) { Fabricate(:post) }
    fab!(:admin) { Fabricate(:admin) }

    before do
      freeze_time
      PostDestroyer.new(admin, post).destroy
    end

    it 'returns error message if same admin and time did not pass' do
      expect(post.cannot_permanently_delete_reason(admin)).to eq(I18n.t('post.cannot_permanently_delete.wait_or_different_admin', time_left: RateLimiter.time_left(Post::PERMANENT_DELETE_TIMER.to_i)))
    end

    it 'returns nothing if different admin' do
      expect(post.cannot_permanently_delete_reason(Fabricate(:admin))).to eq(nil)
    end
  end

  describe "#canonical_url" do
    it 'is able to determine correct canonical urls' do

      # ugly, but no interface to set this and we don't want to create
      # 100 posts to test this thing
      TopicView.stubs(:chunk_size).returns(2)

      post1 = Fabricate(:post)
      topic = post1.topic

      post2 = Fabricate(:post, topic: topic)
      post3 = Fabricate(:post, topic: topic)
      post4 = Fabricate(:post, topic: topic)

      topic_url = post1.topic.url

      expect(post1.canonical_url).to eq("#{topic_url}#post_#{post1.post_number}")
      expect(post2.canonical_url).to eq("#{topic_url}#post_#{post2.post_number}")

      expect(post3.canonical_url).to eq("#{topic_url}?page=2#post_#{post3.post_number}")
      expect(post4.canonical_url).to eq("#{topic_url}?page=2#post_#{post4.post_number}")
    end
  end
end
