# Copyright 2011-2012 Rice University. Licensed under the Affero General Public 
# License version 3 or later.  See the COPYRIGHT file for details.

class Question < ActiveRecord::Base
  include AssetMethods
  
  acts_as_taggable
  
  @@lock_timeout = Quadbase::Application.config.question_lock_timeout

  set_inheritance_column "question_type"
  
  has_many :question_collaborators, 
           :order => :position, 
           :dependent => :destroy
  has_many :collaborators, 
           :through => :question_collaborators,
           :source => :user
  has_many :project_questions, :dependent => :destroy

  belongs_to :license
  belongs_to :question_setup
  belongs_to :publisher, :class_name => "User"

  accepts_nested_attributes_for :question_setup
  
  has_one :question_source, 
          :class_name => "QuestionDerivation",
          :foreign_key => "derived_question_id"
  has_one :source_question, :through => :question_source
           
  has_many :question_derivations,
           :foreign_key => "source_question_id"
  has_many :derived_questions, :through => :question_derivations
    
  has_many :parent_question_parts, 
           :class_name => "QuestionPart",
           :foreign_key => :child_question_id,
           :dependent => :destroy
  has_many :multipart_questions, :through => :parent_question_parts
  
  has_many :attachable_assets, :as => :attachable
  has_many :assets, :through => :attachable_assets

  
  # Sometimes question A is required to be shown before question B.  In this
  # situation, question A is called a prerequisite of question B.  Question B
  # is called a dependent of question A.
  
  has_many :prerequisite_question_pairs,
           :class_name => "QuestionDependencyPair",
           :foreign_key => "dependent_question_id",
           :conditions => { :kind => "requirement" },
           :dependent => :destroy
  has_many :prerequisite_questions,
           :through => :prerequisite_question_pairs,
           :source => :independent_question
           
  has_many :dependent_question_pairs,
           :class_name => "QuestionDependencyPair",
           :foreign_key => "independent_question_id",
           :conditions => { :kind => "requirement" },
           :dependent => :destroy         
  has_many :dependent_questions,
           :through => :dependent_question_pairs
  
  # Sometimes if someone solves question A, it will be easier for them to solve
  # question B.  In this case, A is a supporting question to B.  B is a
  # supported question of A.
   
  has_many :supporting_question_pairs,
           :class_name => "QuestionDependencyPair",
           :foreign_key => "dependent_question_id",
           :conditions => { :kind => "support" },
           :dependent => :destroy
  has_many :supporting_questions,
           :through => :supporting_question_pairs,
           :source => :independent_question

  has_many :supported_question_pairs,
           :class_name => "QuestionDependencyPair",
           :foreign_key => "independent_question_id",
           :conditions => { :kind => "support" },
           :dependent => :destroy
  has_many :supported_questions,
           :through => :supported_question_pairs,
           :source => :dependent_question
           

  has_many :solutions, :dependent => :destroy

  has_one :comment_thread, :as => :commentable, :dependent => :destroy
  before_validation :build_comment_thread, :on => :create
  validates_presence_of :comment_thread

  before_destroy :not_published

  after_destroy :destroy_childless_question_setup
  
  before_create :create_question_setup, :unless => :question_setup

  validate :not_published, :on => :update
  validates_presence_of :license
  
  after_initialize :set_default_license!, :unless => :license

  before_create :assign_number

  scope :draft_questions, where(:version => nil)
  scope :published_questions, where(:version.not_eq => nil)
  scope :questions_in_projects, lambda { |projects|
    joins(:project_questions).where(:project_questions => {
          :project_id => projects.collect { |p| p.id }})
  }
  scope :published_with_number, lambda { |number|
    published_questions.where(:number => number).order("updated_at DESC")
  }

  # This type is passed in some questions params; we need an accessor for it 
  # even though we don't explicitly save it.
  attr_accessor :type
  
  # Disallow mass assignment for certain attributes that should only be
  # modifiable by the system (note that users can modify question_setup data
  # but we don't want them deciding which questions share setups, etc)
  # Using whitelisting instead of blacklisting here.
  attr_accessible :content, :changes_solution, :question_setup_attributes

  def to_param
    if is_published?
      "q#{number}v#{version}"
    else
      "d#{id}"
    end
  end
  
  def self.exists?(param)
    begin
      from_param(param)
      return true
    rescue
      return false
    end
  end
  
  def self.from_param(param)
    if (param =~ /^d(\d+)/)
      q = Question.find($1.to_i) # Rails escapes this
    elsif (param =~ /^q(\d+)(v(\d+))?/)
      if ($3.nil?)
        q = latest_published($1.to_i) # Somewhat dangerous but seems to be properly escaped
      else
        q = find_by_number_and_version($1.to_i, $3.to_i) # Rails escapes this
      end
    else
      raise SecurityTransgression
    end
    
    raise ActiveRecord::RecordNotFound if q.nil?
    q
  end
    
  def self.find_by_number_and_version(number, version)
    Question.first(:conditions => {:number => number, :version => version})
  end
  
  def self.latest_published(number)
    Question.published_with_number(number).first
  end
  
  def prior_version
    has_earlier_versions? ? 
      Question.first(:number.eq % number & :version.eq % version-1) :
      nil
  end
    
  # Called to create the first-ever role for a question, where by default
  # the creator is given all three roles.  Must assign explicitly as the 
  # roles cannot be mass assigned for security reasons.
  def set_initial_question_roles(user)
    q = question_collaborators.create(:user => user)
    q.is_author = true
    q.is_copyright_holder = true
    q.save!
    comment_thread.subscribe!(user)
  end
  
  def run_prepublish_error_checks
    self.errors.add(:base, 'This question has pending role requests.') \
      if !question_role_requests.empty?

    self.errors.add(:base, 'The two question roles are not filled for this question.') \
      if !has_all_roles?
        
    self.errors.add(:base, 'A license has not yet been specified for this question.') \
      if !has_license?
    
    self.errors.add(:base, 'This question is already published.') \
      if is_published?
    
    self.errors.add(:base, 'Newer versions of this question already exist! ' + 
                          'Please start modifications again from the latest version.') \
      if superseded?
        
    add_other_prepublish_errors
  end
  
  # A template method allowing child classes to add to the errors that must
  # be corrected before publishing will be allowed
  def add_other_prepublish_errors 
  end
  
  def ready_to_be_published?
    run_prepublish_error_checks  
    self.errors.empty?    
  end
  
  def publish!(user)
    return if !ready_to_be_published?
    
    # Do some cleanup
    remove_blank_question_setup!
    
    # This hook allows child classes to implement class-specific code that
    # should run before publishing
    run_prepublish_hooks(user)

    roleless_collaborators.each { |rc| rc.destroy }
    comment_thread.clear!
    comment_thread(true) # because .clear! makes new thread!
    
    question_collaborators.each do |qc|
      comment_thread.subscribe!(qc.user) if (qc.has_role?(:author) && 
                                             qc.user.user_profile.auto_author_subscribe)
    end
    
    self.version = next_available_version
    self.publisher = user
    self.save!
  end
  
  def is_published?
    nil != version
  end
  
  def setup_is_changeable?
    !is_published? && question_setup.content_change_allowed?
  end
  
  def has_all_roles?
    author_filled = false
    copyright_filled = false
    
    question_collaborators.each do |qc|
      author_filled ||= qc.is_author
      copyright_filled ||= qc.is_copyright_holder
    end
    
    author_filled && copyright_filled
  end
  
  def has_license?
    nil != license_id
  end
  
  def superseded?
    !latest_published_same_number.nil? && 
    latest_published_same_number.updated_at > self.created_at
  end
  
  def is_latest?
    latest_published_same_number == self
  end
  
  def next_available_version
    latest_published_same_number.nil? ? 
      1 : latest_published_same_number.version + 1
  end

  def latest_published_same_number
    Question.latest_published(self.number)
  end
  
  def is_draft_in_multipart?
    !is_published? && !multipart_questions.empty?
  end
  
  def is_multipart?
    false
  end
  
  def modified_at
    updated_at
  end
  
  def content_summary_string
    raise AbstractMethodCalled
  end
  
  def has_role?(user, role)
    qc = question_collaborators.select{|qc| qc.user_id == user.id}.first    
    qc.nil? ? false : qc.has_role?(role)
  end
  
  def is_collaborator?(user)
    question_collaborators.any?{|qc| qc.user_id == user.id}
  end
  
  def has_role_permission_as_deputy?(user, role)
    # TODO this is probably fairly costly and only applies to a small number
    # of users; so implement a counter_cache of num deputizers and check that
    # before doing this; also User.is_deputy_for? could benefit from what we 
    # do here
    user.deputizers.any? do |deputizer|
      has_role?(deputizer, role)
    end
  end
  
  def has_role_permission?(user, role)
    !user.is_anonymous? && (has_role?(user, role) || has_role_permission_as_deputy?(user, role))
  end

  def question_role_requests
    QuestionRoleRequest.for_question(self)
  end
  
  # Saves the question (for the first time), assigns roles to the given user,
  # and puts the question in the user's default project.  Throws exceptions
  # on errors.
  def create!(user, options ={})
    options[:set_initial_roles] = true if options[:set_initial_roles].nil?
    options[:project] = Project.default_for_user!(user) if options[:project].nil?

    Question.transaction do
      self.save!
      self.set_initial_question_roles(user) if options[:set_initial_roles]
      options[:project].add_question!(self)
      QuestionDerivation.create(
        :source_question_id => options[:source_question].id,
        :deriver_id => options[:deriver_id],
        :derived_question_id => self.id) if (options[:source_question] &&
                                             options[:deriver_id])
    end
  end
  
  def new_derivation!(user, project = nil)
    return if !is_published?
    derived_question = self.content_copy
    
    Question.transaction do
      derived_question.create!(user, :project => project)
      QuestionDerivation.create(:source_question_id => self.id, 
                                :derived_question_id => derived_question.id,
                                :deriver_id => user.id)
    end
    
    derived_question
  end
  
  def new_version!(user, project = nil)
    new_version = self.content_copy
    new_version.number = self.number
    new_version.version = nil
    
    new_version.create!(user, {:project => project, :set_initial_roles => false})
    QuestionCollaborator.copy_roles(self, new_version)
    new_version
  end
  
  # Makes a new question that has a copy of the content in this question
  def content_copy
    raise AbstractMethodCalled
  end

  # Sets common question properties, given a copied question object
  def init_copy(kopy)
    kopy.question_setup = self.question_setup.content_copy if !self.question_setup_id.nil?
    kopy.license_id = self.license_id
    self.attachable_assets.each {|aa| kopy.attachable_assets.push(aa.content_copy) }
    kopy.tag_list = self.tag_list
    kopy
  end
  
  def is_derivation?
    !question_source.nil?
  end
  
  def has_earlier_versions?
    0 != version && !version.nil?
  end
  
  def get_ancestor_question
    has_earlier_versions? ? prior_version : (is_derivation? ? source_question : nil)
  end

  def can_be_joined_by?(user)
    !has_role?(user, :is_listed)
  end
  
  def self.search(type, where, text, user)

    query = text.blank? ? '%' : '%' + text + '%'
    # Note: % is the wildcard. This allows the user to search for stuff that "begins with" and "ends with".

    case type # The tquery values here might have to change once we actually implement these. Also, make sure the "when" values match the template.
    when 'Simple Questions'
      tquery = 'SimpleQuestion'
    when 'Matching Questions'
      tquery = 'MatchingQuestion'
    when 'Multipart Questions'
      tquery = 'MultipartQuestion'
    else
      tquery = '%'
    end

    case where
    when 'Published Questions'
      wscope = published_questions
    when 'My Drafts'
      wscope = draft_questions
    when 'My Projects'
      wscope = user_project_questions(user)
    else
      wscope = Question
    end

    wscope.where(:content.matches % query & :question_type.matches % tquery)
  end

  def roleless_collaborators
    question_collaborators.where(:is_author => false,
                                 :is_copyright_holder => false)
  end

  def valid_solutions_visible_for(user)
    s = solutions.visible_for(user)
    return s if changes_solution
    previous_published_questions = Question.published_with_number(number)
    previous_published_questions = previous_published_questions.where(:version.lt => version) \
                                     if is_published?
    previous_published_questions.each do |pq|
      s |= pq.solutions.visible_for(user)
      break if pq.changes_solution
    end
    s
  end
  
  def base_class
    Question
  end
  
  # In some cases, there could be some outstanding role requests on this question
  # but no role holders left to approve/reject them.  This method is a utility for
  # automatically granting all of those roles.
  def grant_all_requests_if_no_role_holders_left!
    if question_collaborators.none?{|qc| qc.has_role?(:any)}
      question_collaborators.each do |qc|
        qc.question_role_requests.each{|qrr| qrr.grant!}
      end
    end
  end
  
  
  #############################################################################
  # Access control methods
  #############################################################################

  def get_lock!(user)
    # This method checks that the user can get the lock and, if so, gets it and returns true.
    # Othewise, returns false.
    return true if @@lock_timeout <= 0
    if (!is_locked? || has_lock?(user))
      return lock!(user)
    end
    already_locked_error
  end

  def check_and_unlock!(user)
    # This method checks that the user has the lock and, if so, releases it and returns true.
    # Othewise, returns false.
    return true if @@lock_timeout <= 0
    if (is_locked? && has_lock?(user))
      return unlock!
    elsif (!is_locked?)
      errors.add(:base, "You do not currently have the lock on draft " + to_param +
                        " (q. " + number.to_s + "). This is usually caused by long periods" +
                        " of inactivity. Please try again.")
      return false
    end
    already_locked_error
  end

  def is_locked?
    locked_by && locked_by > 0 && locked_at && Time.current < (locked_at + @@lock_timeout)
  end

  def has_lock?(user)
    # This method assumes is_locked == true
    locked_by == user.id
  end

  def can_be_read_by?(user)
    is_published? || 
    ( !user.is_anonymous? && 
      (is_project_member?(user) || has_role_permission?(user, :any)) )
  end
    
  def can_be_created_by?(user)
    !user.is_anonymous?
  end
  
  def can_be_updated_by?(user)
    !is_published? && !user.is_anonymous? && 
    (is_project_member?(user) || has_role_permission?(user, :any))
  end
  
  def can_be_destroyed_by?(user)
    !is_published? && !user.is_anonymous? && 
    (is_project_member?(user) || has_role_permission?(user, :any))
  end
  
  def can_be_published_by?(user)
    !is_published? && !user.is_anonymous? && has_role_permission?(user, :any)
  end
  
  def can_be_new_versioned_by?(user)
    is_published? && is_latest? &&
    !user.is_anonymous? && has_role_permission?(user, :any)
  end
  
  def can_be_derived_by?(user)
    is_published? && !user.is_anonymous?
  end
  
  def can_be_tagged_by?(user)
    can_be_updated_by?(user) || has_role_permission?(user, :any)
  end
  
  # Special access method for role requests on this collaborator
  # defined here b/c called from different places
  def role_requests_can_be_created_by?(user)
    user.can_update?(self)
  end
  
#############################################################################
protected
#############################################################################
    
  # Only assign a question number if the current number is nil.  When a new version
  # of an existing question is made, the number will already be set to the correct
  # value before this method is called.
  def assign_number
    self.number ||= (Question.maximum(:number) || 1) + 1
  end
  
  def not_published
    return if (version_was.nil?)
    errors.add(:base, "Changes cannot be made to a published question.#{self.changes}")
    false
  end
  
  def remove_blank_question_setup!
    if question_setup.content.blank?
      setup = self.question_setup
      self.question_setup = nil
      self.save!
      setup.destroy_if_unattached
    end
  end

  def is_project_member?(user)
    project_questions.each { |wp| return true if wp.project.is_member?(user) }
    false
  end

  def self.user_project_questions(user)
    questions_in_projects(Project.all_for_user(user))
  end

  def set_default_license!
    self.license = License.default
  end

  def destroy_childless_question_setup
    if !question_setup.blank?
      question_setup.destroy_if_unattached
    end
  end

  def lock!(user)
    self.locked_by = user.id
    self.locked_at = Time.now
    save
  end

  def unlock!
    self.locked_by = -1
    save
  end

  def already_locked_error
    lock_minutes = ((locked_at + @@lock_timeout - Time.now)/60).ceil
    errors.add(:base, "Draft " + to_param + " (q. " + number.to_s +
                      ") is currently locked by " +
                      User.find(locked_by).full_name + " for at least " +
                      lock_minutes.to_s +
                      " more " + (lock_minutes == 1 ? "minute" : "minutes") + ".")
    false
  end
  
  # Template method overridable by a child class for child-specific behavior
  def run_prepublish_hooks(user); end

end
