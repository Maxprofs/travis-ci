require 'core_ext/array/flatten_once'

class Build < ActiveRecord::Base
  belongs_to :repository
  belongs_to :parent, :class_name => 'Build', :foreign_key => :parent_id

  has_many :matrix, :class_name => 'Build', :foreign_key => :parent_id

  validates :repository_id, :presence => true

  serialize :config

  before_save :expand_matrix!, :if => :expand_matrix?

  after_save :denormalize_to_repository, :if => :denormalize_to_repository?
  after_save :sync_changes

  class << self
    def create_from_github_payload(data)
      repository = Repository.find_or_create_by_url(data['repository']['url'])
      commit     = data['commits'].last
      author     = commit['author'] || {}
      committer  = commit['committer'] || author || {}

      repository.builds.create(
        :commit          => commit['id'],
        :message         => commit['message'],
        :number          => repository.builds.count + 1,
        :committed_at    => commit['timestamp'],
        :committer_name  => committer['name'],
        :committer_email => committer['email'],
        :author_name     => author['name'],
        :author_email    => author['email']
      )
    end

    def started
      where(arel_table[:started_at].not_eq(nil))
    end
  end

  attr_accessor :log_appended, :msg_id

  def log_appended?
    log_appended.present?
  end

  def append_log!(chars, msg_id)
    self.log_appended = chars
    self.msg_id = msg_id
    update_attributes!(:log => [self.log, chars].join)
  end

  def started?
    started_at.present?
  end

  def was_started?
    started? && started_at_changed?
  end

  def finished?
    finished_at.present?
  end

  def was_finished?
    finished? && finished_at_changed?
  end

  def pending?
    !finished?
  end

  def passed?
    status == 0
  end

  def color
    pending? ? '' : passed? ? 'green' : 'red'
  end

  def matrix?
    parent_id.blank? && matrix_config?
  end

  def matrix_expanded?
    Travis::Buildable::Config.matrix?(@previously_changed['config'][1]) rescue false # TODO how to use some public AR API?
  end

  all_attrs = [:id, :repository_id, :parent_id, :number, :commit, :message, :status, :log, :started_at, :committed_at,
    :committer_name, :committer_email, :author_name, :author_email, :config]

  JSON_ATTRS = {
    :default          => all_attrs,
    :job              => [:id, :commit, :config],
    :'build:queued'   => [:id, :number],
    :'build:started'  => all_attrs - [:status, :log],
    :'build:log'      => [:id],
    :'build:finished' => [:id, :status, :finished_at],
  }

  def as_json(options = nil)
    options ||= {}
    json = super(:only => JSON_ATTRS[options[:for] || :default])
    json.merge!(:matrix => matrix.as_json(:for => :'build:started')) if matrix?
    json
  end

  protected

    def expand_matrix?
      matrix? && matrix.empty?
    end

    def expand_matrix!
      expand_matrix_config(matrix_config.to_a).each_with_index do |row, ix|
        matrix.build(attributes.merge(:number => "#{number}.#{ix + 1}", :config => Hash[*row.flatten]))
      end
    end

    def matrix_config?
      matrix_config.present?
    end

    def matrix_config
      @matrix_config ||= begin
        config = self.config || {}
        keys   = Travis::Buildable::Config::ENV_KEYS & config.keys
        size   = config.slice(*keys).values.select { |value| value.is_a?(Array) }.max { |lft, rgt| lft.size <=> rgt.size }.try(:size) || 1

        keys.inject([]) do |result, key|
          values = config[key]
          values = [values] unless values.is_a?(Array)
          values += [values.last] * (size - values.size) if values.size < size
          result << values.map { |value| [key, value] }
        end if size > 1
      end
    end

    def expand_matrix_config(config)
      # recursively builds up permutations of values in the rows of a nested array
      matrix = lambda do |*args|
        base, result = args.shift, args.shift || []
        base = base.dup
        base.empty? ? [result] : base.shift.map { |value| matrix.call(base, result + [value]) }.flatten_once
      end
      matrix.call(config)
    end

    def denormalize_to_repository?
      repository.last_build == self && changed & %w(number status started_at finished_at)
    end


    def denormalize_to_repository
      repository.update_attributes!(
        :last_build_id => id,
        :last_build_number => number,
        :last_build_status => status,
        :last_build_started_at => started_at,
        :last_build_finished_at => finished_at
      )
    end

    def sync_changes
      if was_started?
        push 'build:started', 'build' => as_json(:for => :'build:started'), 'repository' => repository.as_json(:for => :'build:started')
      elsif log_appended?
        push 'build:log', 'build' => as_json(:for => :'build:log'), 'repository' => repository.as_json(:for => :'build:log'), 'log' => log_appended, 'msg_id' => msg_id
      elsif was_finished?
        push 'build:finished', 'build' => as_json(:for => :'build:finished'), 'repository' => repository.as_json(:for => :'build:finished')
      end
    end

    def push(event, data)
      Pusher['repositories'].trigger(event, data) # if Travis.pusher
    end
end
