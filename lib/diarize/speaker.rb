require 'rubygems'
require 'rdf_mapper'
require 'jblas'

module Diarize

  class Speaker

    include JBLAS

    # Some possible matching heuristics if using GDMAP:
    # - speaker mean_log_likelihood needs to be more than -33 to be considered for match
    # - distance between two speakers need to be less than distance between speaker and universal model + detection threshold to be considered

    @@log_likelihood_threshold = -33
    @@detection_threshold = 0.2 # Need to learn that parameter

    @@speakers = {}

    attr_accessor :model, :model_uri
    attr_reader :gender

    def initialize(uri = nil, gender = nil, model_file = nil)
      unless model_file
        # A generic speaker, associated with a universal background model
        @model = Speaker.load_model(File.join(File.expand_path(File.dirname(__FILE__)), 'ubm.gmm'))
        # We don't attempt to normalize the UBM
        @normalized = true
      else
        @model = Speaker.load_model(model_file)
        @normalized = false
      end
      @uri = uri
      @gender = gender
    end

    def mean_log_likelihood
      @mean_log_likelihood ? @mean_log_likelihood : model.mean_log_likelihood # Will be NaN if model was loaded from somewhere
    end

    def mean_log_likelihood=(mll)
      @mean_log_likelihood = mll
    end

    def save_model(filename)
      # TODO perhaps a warning if a normalised model is being saved?
      write_gmm(filename, @model)
    end

    def self.detection_threshold=(threshold)
      @@detection_threshold = threshold
    end

    def self.detection_threshold
      @@detection_threshold
    end

    def self.load_model(filename)
      read_gmm(filename)
    end

    def self.find_or_create(uri, gender)
      return @@speakers[uri] if @@speakers[uri]
      @@speakers[uri] = Speaker.new(uri, gender)
    end

    def self.divergence(speaker1, speaker2)
      # TODO bundle in mean_log_likelihood to weight down unlikely models? 
      return unless speaker1.model and speaker2.model
      # MAP Gaussian divergence
      # See "A model space framework for efficient speaker detection", Interspeech'05
      divergence_lium(speaker1, speaker2)
    end

    def self.divergence_lium(speaker1, speaker2)
      fr.lium.spkDiarization.libModel.Distance.GDMAP(speaker1.model, speaker2.model)
    end

    def self.divergence_ruby(speaker1, speaker2)
      gaussian_weights_supervector_ubm.mul(((speaker1.supervector - speaker2.supervector) ** 2) / covariance_supervector_ubm).sum
    end

    def self.gaussian_weights_supervector_ubm
      @@gaussian_weights_supervector_ubm ||= ( 
        ubm = new
        weights = DoubleMatrix.new(ubm.supervector_dim, 1)
        ubm.model.nb_of_components.times do |k|
          gaussian = ubm.model.components.get(k)
          gaussian.dim.times do |i|
            weights[k * gaussian.dim + i] = gaussian.weight
          end
        end
        weights
      )
    end

    def self.covariance_supervector_ubm
      @@covariance_supervector_ubm ||= (
        ubm = new
        cov_supervector = DoubleMatrix.new(ubm.supervector_dim, 1)
        ubm.model.nb_of_components.times do |k|
         gaussian = ubm.model.components.get(k)
          gaussian.dim.times do |i|
            cov_supervector[k * gaussian.dim + i] = gaussian.getCovariance(i, i)
          end
        end
        cov_supervector
      )
    end

    def self.match_sets(speakers1, speakers2)
      matches = []
      speakers1.each do |s1|
        speakers2.each do |s2|
          matches << [ s1, s2 ] if s1.same_speaker_as(s2)
        end
      end
      matches
    end

    def self.match(speakers)
      speakers.combination(2).select { |s1, s2| s1.same_speaker_as(s2) }
    end

    def normalize!
      unless @normalized
        # Applies M-Norm from "D-MAP: a Distance-Normalized MAP Estimation of Speaker Models for Automatic Speaker Verification"
        # to the associated GMM, placing it on a unit hyper-sphere with a UBM centre (model will be at distance one from the UBM
        # according to GDMAP)
        speaker_ubm = Speaker.new
        distance_to_ubm = Math.sqrt(Speaker.divergence(self, speaker_ubm))
        model.nb_of_components.times do |k|
          gaussian = model.components.get(k)
          gaussian.dim.times do |i|
            normalized_mean = (1.0 / distance_to_ubm) * gaussian.mean(i) + (1.0 - 1.0 / distance_to_ubm)  * speaker_ubm.model.components.get(k).mean(i)
            gaussian.set_mean(i, normalized_mean) 
          end
        end
        @normalized = true
      end
      @normalized
    end

    def same_speaker_as(other)
      # Detection score defined in Ben2005
      return unless [ self.mean_log_likelihood, other.mean_log_likelihood ].min > @@log_likelihood_threshold
      self.normalize!
      other.normalize!
      detection_score = 1.0 - Speaker.divergence(other, self)
      detection_score > @@detection_threshold
    end

    def supervector_dim
      @supervector_dim ||= model.nb_of_components * model.components.get(0).dim
    end

    def supervector
      @supervector ||= (
        supervector = DoubleMatrix.new(supervector_dim, 1)
        model.nb_of_components.times do |k|
          gaussian = model.components.get(k)
          gaussian.dim.times do |i|
            supervector[k * gaussian.dim + i] = gaussian.mean(i)
          end
        end
        supervector
      )
    end

    include RdfMapper

    def namespaces
      super.merge 'ws' => 'http://wsarchive.prototype0.net/ontology/'
    end

    def uri
      @uri
    end

    def type_uri
      'ws:Speaker'
    end

    def rdf_mapping
      { 'ws:gender' => gender, 'ws:model' => model_uri, 'ws:mean_log_likelihood' => model.mean_log_likelihood }
    end 

    protected

    def self.read_gmm(filename)
      gmmlist = java.util.ArrayList.new
      input = fr.lium.spkDiarization.lib.IOFile.new(filename, 'rb')
      input.open
      fr.lium.spkDiarization.libModel.ModelIO.readerGMMContainer(input, gmmlist)
      input.close
      gmmlist.to_a.first
    end

    def write_gmm(filename, model)
      gmmlist = java.util.ArrayList.new
      gmmlist << model
      output = fr.lium.spkDiarization.lib.IOFile.new(filename, 'wb')
      output.open
      fr.lium.spkDiarization.libModel.ModelIO.writerGMMContainer(output, gmmlist)
      output.close
    end

  end

end
