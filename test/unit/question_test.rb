# encoding: UTF-8

# Copyright 2011-2012 Rice University. Licensed under the Affero General Public 
# License version 3 or later.  See the COPYRIGHT file for details.

require 'test_helper'

class QuestionTest < ActiveSupport::TestCase

  fixtures
  self.use_transactional_fixtures = true

  test "can't mass-assign number, version, question_type, license_id, content_html, locked_by, locked_at" do
    number = 20
    version = 11
    question_type = "MultipartQuestion"
    license_id = 10
    content_html = "Some content"
    locked_by = 15
    locked_at = Time.now
    sq = SimpleQuestion.new(:number => number,
                            :version => version,
                            :question_type => question_type,
                            :license_id => license_id,
                            :content_html => content_html,
                            :locked_by => locked_by,
                            :locked_at => locked_at)
    assert sq.number != number
    assert sq.version != version
    assert sq.question_type != question_type
    assert sq.license_id != license_id
    assert sq.content_html != content_html
    assert sq.locked_by != locked_by
    assert sq.locked_at != locked_at
  end

  test "published question ID" do
    sq = make_simple_question({:answer_credits => [0,1,0,0], 
                               :published => true,
                               :method => :create})

    assert_equal "q#{sq.number}v1", sq.to_param
  end
  
  test "draft question ID" do
    q = make_simple_question
    assert_equal "d#{q.id}", q.to_param
  end
  
  test "publish" do
    q = make_simple_question(:method => :create, :set_license => true)
    u = Factory.create(:user)
    q.set_initial_question_roles(u)
    
    assert_nothing_raised(ActiveRecord::RecordInvalid) {q.publish!(u)}
    assert_equal 1, q.version
    assert q.is_published?
  end
  
  # test "can't publish because superseded" do
  #   # q_pub = make_simple_question(:method => :create, :set_license => true, :published => :true)
  #   
  #   flunk "Not yet implemented"
  # end
  
  test "can't publish because already published" do 
    q_pub = make_simple_question(:method => :create, :set_license => true, :published => :true)
    q_pub.publish!(Factory.create(:user))
    assert !q_pub.errors.empty?
  end
  
  test "can't publish because missing roles" do 
    q = make_simple_question()
    u = Factory.create(:user)
    q.publish!(u)
    assert !q.errors.empty?
  end
  
  # test "publishing assigns incrementing number" do 
  #   flunk "Not yet implemented"
  # end

  test "can't destroy published questions" do 
    q = make_simple_question(:method => :create, :published => true)
    q.destroy
    
    assert !q.errors.empty?
    assert_nothing_raised(ActiveRecord::RecordNotFound) { Question.find(q.id) }
  end

  # test "find by number and version" do 
  #   flunk "Not yet implemented"
  # end
  
  test "has_all_roles" do
    q = make_simple_question
    u = Factory.create(:user)
    
    c = Factory.create(:question_collaborator, {:question => q, 
                                                :user => u, 
                                                :is_author => true,
                                                :is_copyright_holder => true})
                                        
    assert q.has_all_roles?
    
    c.is_author = false
    c.save!
    q.reload
    
    assert !q.has_all_roles?
    
    c.is_author = true
    c.is_copyright_holder = false
    c.save!
    q.reload
    
    assert !q.has_all_roles?
  end
  
  test "superseded" do 
    q1 = make_simple_question(:method => :build)
    u = Factory.create(:user)
    q1.create!(u)
    q1.publish!(u)
    
    q2 = q1.new_version!(Factory.create(:user))
    q3 = q1.new_version!(Factory.create(:user))
    
    assert !q2.superseded?
    
    q3.publish!(u)
    
    assert q2.superseded?
  end
  
  # test "is_latest?" do 
  #   flunk "Not yet implemented"
  # end
  
  test "next available version" do 
    q = make_simple_question(:method => :create, :published => true)
    assert_equal 2, q.next_available_version
  end
  
  test "delete destroys appropriate assocs" do
    q = make_simple_question()
    wq = Factory.create(:project_question, :question => q)
    c = Factory.create(:question_collaborator, :question => q)

    q.destroy
    assert_raise(ActiveRecord::RecordNotFound) { Question.find(q.id) }

    assert_raise(ActiveRecord::RecordNotFound) { QuestionCollaborator.find(c.id) }
    assert_raise(ActiveRecord::RecordNotFound) { ProjectQuestion.find(wq.id) }
  end
  
  test "create" do
    q = make_simple_question()
    u = Factory.create(:user)
    
    q.create!(u)
    
    assert_nothing_raised(ActiveRecord::RecordNotFound) { Question.find(q.id) }
    q = Question.find(q.id)
    assert q.has_role?(u, :author)
    assert q.has_role?(u, :copyright_holder)
    assert Project.default_for_user!(u).questions(true).include?(q)
  end
  
  test "new_derivation!" do
    q = make_simple_question(:set_license => true)
    u = Factory.create(:user)
    q.create!(u)
    q.publish!(u)
    
    q_derived = q.new_derivation!(u)
    
    assert_equal q_derived.source_question.id, q.id
    assert_not_equal q_derived.id, q.id
    assert_nil q_derived.version
    assert q_derived.has_role?(u, :author)
    assert q_derived.has_role?(u, :copyright_holder)
    
    assert_equal q_derived.content, q.content
    assert_equal q_derived.license_id, q.license_id
    
    #TODO test derived_questions and source_question
  end

  test "copy_with_derivation" do
    q = make_simple_question(:set_license => true)
    u = Factory.create(:user)
    q.create!(u)
    q.publish!(u)
    
    q_derived = q.new_derivation!(u)

    qc = q_derived.content_copy
    qc.create!(u, :source_question => q_derived.source_question, :deriver_id => u.id)

    assert_equal qc.source_question, q
    assert_equal qc.question_source.deriver, u
  end
  
  test "new_version!" do
    q = make_simple_question(:set_license => true)
    u = Factory.create(:user)
    q.create!(u)
    q.publish!(u)
    
    q_newver = q.new_version!(u)
    
    assert_equal q_newver.number, q.number
    assert_nil q_newver.version
    assert q_newver.has_role?(u, :author)
    assert q_newver.has_role?(u, :copyright_holder)
    
    q_newver.publish!(u)
    
    assert_equal q.version+1, q_newver.version
    
    #TODO test prior_version
  end

  test 'question search' do
    sq0 = Factory.create(:simple_question, :content => '')
    sq1 = Factory.create(:simple_question, :content => 'This is in your project')
    sq2 = Factory.create(:simple_question, :content => 'This is NOT in your project')
    sq3 = Factory.create(:simple_question, :content => 'This is published', :version => '1.0')
    sq4 = Factory.create(:simple_question, :content => 'This is published and in your project', :version => '1.0')

    user = Factory.create(:user)
    Factory.create(:project_question, :question => sq0,
                   :project => Project.default_for_user!(user))
    Factory.create(:project_question, :question => sq1,
                   :project => Project.default_for_user!(user))
    Factory.create(:project_question, :question => sq4,
                   :project => Project.default_for_user!(user))

    search0 = Question.search('All Questions', 'All Places', '', user)
    search1 = Question.search('All Questions', 'Published Questions', '', user)
    search2 = Question.search('All Questions', 'My Drafts', '', user)
    search3 = Question.search('All Questions', 'My Projects', '', user)
    search4 = Question.search('All Questions', 'All Places', 'not', user)
    search5 = Question.search('All Questions', 'My Projects', 'this', user)

    assert search0.include?(sq0)
    assert search0.include?(sq1)
    assert search0.include?(sq2)
    assert search0.include?(sq3)
    assert search0.include?(sq4)

    assert !search1.include?(sq0)
    assert !search1.include?(sq1)
    assert !search1.include?(sq2)
    assert search1.include?(sq3)
    assert search1.include?(sq4)

    assert search2.include?(sq0)
    assert search2.include?(sq1)
    assert search2.include?(sq2)
    assert !search2.include?(sq3)
    assert !search2.include?(sq4)

    assert search3.include?(sq0)
    assert search3.include?(sq1)
    assert !search3.include?(sq2)
    assert !search3.include?(sq3)
    assert search3.include?(sq4)

    assert !search4.include?(sq0)
    assert !search4.include?(sq1)
    assert search4.include?(sq2)
    assert !search4.include?(sq3)
    assert !search4.include?(sq4)

    assert !search5.include?(sq0)
    assert search5.include?(sq1)
    assert !search5.include?(sq2)
    assert !search5.include?(sq3)
    assert search5.include?(sq4)
  end

  test 'simple question search' do
    sq0 = Factory.create(:simple_question, :content => '')
    sq1 = Factory.create(:simple_question, :content => 'This is in your project')
    sq2 = Factory.create(:simple_question, :content => 'This is NOT in your project')
    sq3 = Factory.create(:simple_question, :content => 'This is published', :version => '1.0')
    sq4 = Factory.create(:simple_question, :content => 'This is published and in your project', :version => '1.0')

    user = Factory.create(:user)
    Factory.create(:project_question, :question => sq0,
                   :project => Project.default_for_user!(user))
    Factory.create(:project_question, :question => sq1,
                   :project => Project.default_for_user!(user))
    Factory.create(:project_question, :question => sq4,
                   :project => Project.default_for_user!(user))

    search0 = Question.search('Simple Questions', 'All Places', '', user)
    search1 = Question.search('Simple Questions', 'Published Questions', '', user)
    search2 = Question.search('Simple Questions', 'My Drafts', '', user)
    search3 = Question.search('Simple Questions', 'My Projects', '', user)
    search4 = Question.search('Simple Questions', 'All Places', 'not', user)
    search5 = Question.search('Simple Questions', 'My Projects', 'this', user)

    assert search0.include?(sq0)
    assert search0.include?(sq1)
    assert search0.include?(sq2)
    assert search0.include?(sq3)
    assert search0.include?(sq4)

    assert !search1.include?(sq0)
    assert !search1.include?(sq1)
    assert !search1.include?(sq2)
    assert search1.include?(sq3)
    assert search1.include?(sq4)

    assert search2.include?(sq0)
    assert search2.include?(sq1)
    assert search2.include?(sq2)
    assert !search2.include?(sq3)
    assert !search2.include?(sq4)

    assert search3.include?(sq0)
    assert search3.include?(sq1)
    assert !search3.include?(sq2)
    assert !search3.include?(sq3)
    assert search3.include?(sq4)

    assert !search4.include?(sq0)
    assert !search4.include?(sq1)
    assert search4.include?(sq2)
    assert !search4.include?(sq3)
    assert !search4.include?(sq4)

    assert !search5.include?(sq0)
    assert search5.include?(sq1)
    assert !search5.include?(sq2)
    assert !search5.include?(sq3)
    assert search5.include?(sq4)
  end
  
  test "dependency_pair" do
    prereq = make_simple_question(:publish => true, :method => :create)
    dependent = make_simple_question(:publish => false, :method => :create)
    
    supporting = make_simple_question(:publish => true, :method => :create)
    supported = make_simple_question(:publish => false, :method => :create)
    
    qdpr = Factory.create(:question_dependency_pair, 
                          :independent_question => prereq, 
                          :dependent_question => dependent, 
                          :kind => "requirement")
    
    qdps = Factory.create(:question_dependency_pair, 
                          :independent_question => supporting, 
                          :dependent_question => supported, 
                          :kind => "support")
    
    assert_equal prereq.dependent_question_pairs.count, 1
    assert prereq.dependent_question_pairs.first.is_requirement?
    assert_equal prereq.dependent_questions.first, dependent
    assert_equal dependent.prerequisite_questions.first, prereq
    
    assert_equal supporting.supported_question_pairs.count, 1
    assert supporting.supported_question_pairs.first.is_support?
    assert_equal supporting.supported_questions.first, supported
    assert_equal supported.supporting_questions.first, supporting
  end

  test 'get_lock' do
    q = Factory.create(:simple_question)
    u = Factory.create(:user)
    u2 = Factory.create(:user)
    assert !q.is_locked?
    assert !q.has_lock?(u)
    assert !q.has_lock?(u2)
    assert q.get_lock!(u)
    assert q.is_locked?
    assert q.has_lock?(u)
    assert !q.has_lock?(u2)
    assert !q.get_lock!(u2)
    assert q.is_locked?
    assert q.has_lock?(u)
    assert !q.has_lock?(u2)
  end

  test 'check_and_unlock' do
    q = Factory.create(:simple_question)
    u = Factory.create(:user)
    u2 = Factory.create(:user)
    assert !q.is_locked?
    assert !q.has_lock?(u)
    assert !q.has_lock?(u2)
    assert !q.check_and_unlock!(u)
    assert !q.check_and_unlock!(u2)
    assert q.get_lock!(u)
    assert q.is_locked?
    assert q.has_lock?(u)
    assert q.check_and_unlock!(u)
    assert !q.is_locked?
    assert !q.has_lock?(u)
  end
  
  test "has_role_permission_as_deputy" do
    qc = Factory.create(:question_collaborator, :is_author => true)
    dep_user = Factory.create(:user)
    Factory.create(:deputization, :deputizer => qc.user, :deputy => dep_user)
    
    assert !qc.user.deputies.empty?
    assert !dep_user.deputizers.empty?
    
    assert qc.question.has_role_permission_as_deputy?(dep_user, :any)
    assert qc.question.has_role_permission?(dep_user, :any)
  end
  
  test "blank setups removed on publish" do
    sq = Factory.create(:simple_question, :question_setup => Factory.create(:question_setup, :content => ""))
    u = Factory.create(:user)
    
    sq.create!(u)
    
    assert !sq.question_setup.nil?
    qs_id = sq.question_setup.id
    
    sq.publish!(u)
    sq.reload
    
    assert sq.question_setup.nil?
    assert_raise(ActiveRecord::RecordNotFound) {QuestionSetup.find(qs_id)}
  end
  
  test "funny characters" do
    q = make_simple_question(:method => :create)
    assert_nothing_raised{q.update_attributes({:content => "\n â".encode("UTF-8")})}
  end
  
  # test "derive with errored question doesn't create QuestionDerivation" do
  #   flunk "Not yet implemented"
  # end
  
  # TODO implement the following tests
  # 
  # test "project_member can publish" do
  # end
  #
  # test "is_derivation?" do
  # end
  # 
  # test "has_earlier_versions?" do
  # end
  # 
  # test "get_ancestor_question" do
  # end
  # 
  # test "assign_number" do
  # end
  
  
end
