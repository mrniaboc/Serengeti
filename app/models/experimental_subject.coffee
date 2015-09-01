Subject = require 'models/subject'
User = require 'zooniverse/lib/models/user'
Experiments = require 'lib/experiments'
Api = require 'zooniverse/lib/api'
AnalyticsLogger = require 'lib/analytics'
Geordi = require 'lib/geordi'

# An Experimental Subject is a specialized subject for use in experiments.
class ExperimentalSubject extends Subject
  @configure "ExperimentalSubject", 'zooniverseId', 'workflowId', 'location', 'coords', 'metadata'

  # override parent as we need additional info
  @fromJSON: (raw) =>
    if !Experiments.sources[raw.zooniverse_id]?
      Experiments.sources[raw.zooniverse_id]=Experiments.SOURCE_NORMAL

    subject = @create
      id: raw.id
      zooniverseId: raw.zooniverse_id
      workflowId: raw.workflow_ids[0]
      location: raw.location
      coords: raw.coords
      metadata: raw.metadata
    # Preload images.
    (new Image).src = src for src in subject.location.standard
    subject

  # same as parent, but this one logs experimental insertions as they are presented to the user, and marks them as seen
  @selectFirstNonEmptySubject: ->
    first = @first()
    first?.destroy() if first?.metadata.empty
    numberOfSubjectsAlreadyLoaded = @count()
    if numberOfSubjectsAlreadyLoaded is 0
      @trigger 'no-subjects'
    else
      subject = @first()
      AnalyticsLogger.logEvent 'view',null,subject.zooniverseId
      if Experiments.ACTIVE_EXPERIMENT=="SerengetiInterestingAnimalsExperiment1"
        if Experiments.currentCohort == Experiments.COHORT_CONTROL
          AnalyticsLogger.logEvent 'control','random',Geordi.UserGetter.currentUserID,subject.zooniverseId
        else if Experiments.currentCohort == Experiments.COHORT_INSERTION
          if Experiments.sources[subject.zooniverseId] == Experiments.SOURCE_INSERTED
            AnalyticsLogger.logEvent 'insertion','specific',subject.zooniverseId
          else if Experiments.sources[subject.zooniverseId] == Experiments.SOURCE_RANDOM
            AnalyticsLogger.logEvent 'insertion','random',Geordi.UserGetter.currentUserID,subject.zooniverseId
        else
          AnalyticsLogger.logEvent 'non-experimental','view',Geordi.UserGetter.currentUserID,subject.zooniverseId
        @markAsSeen subject.zooniverseId
      else if Experiments.ACTIVE_EXPERIMENT=="SerengetiBlanksExperiment1"
        if Experiments.currentCohort == Experiments.COHORT_CONTROL
          AnalyticsLogger.logEvent 'control','random',subject.zooniverseId
        else if Experiments.currentCohort in [Experiments.COHORT_0, Experiments.COHORT_20, Experiments.COHORT_40, Experiments.COHORT_60, Experiments.COHORT_80]
          if Experiments.sources[subject.zooniverseId] == Experiments.SOURCE_BLANK
            AnalyticsLogger.logEvent 'insertion','blank',subject.zooniverseId
          else if Experiments.sources[subject.zooniverseId] == Experiments.SOURCE_NON_BLANK
            AnalyticsLogger.logEvent 'insertion','non-blank',subject.zooniverseId
        else
          AnalyticsLogger.logEvent 'non-experimental','view',subject.zooniverseId
        @markAsSeen subject.zooniverseId
      subject.select()

  # get a specific subject by ID from the API and instantiate it as a model
  @subjectFetch: (subjectID) =>
    subjectFetcher = new $.Deferred

    getter = Api.get("/projects/serengeti/subjects/#{subjectID}").deferred

    getter.done (rawSubject) =>
      subjectFetcher.resolve (@fromJSON rawSubject)

    getter.fail =>
      # resort to a random image
      @fetch(1).done (rawSubject) =>
        rawSubject.missing = true
        subjectFetcher.resolve (@fromJSON rawSubject)

    subjectFetcher.promise()

  # instantiates more subjects, at random but does not do anything with them
  @loadMoreRandomSubjects: (numberOfSubjectsToFetch) =>
    @fetch numberOfSubjectsToFetch unless numberOfSubjectsToFetch < 1

  # instantiates more subjects, according to experiment, but doesn't do anything with them
  @loadMoreExperimentalSubjects: (numberOfSubjectsToFetch) =>
    if numberOfSubjectsToFetch >= 1
      backgroundFetcher = @getNextSubjectIDs numberOfSubjectsToFetch
      backgroundFetcher
      .then (response) =>
        if response?
          Experiments.currentParticipant = response.participant
          nextSubjectIDs = response.nextSubjectIDs
          if nextSubjectIDs? && nextSubjectIDs.length == 0
            # end of experiment
            Experiments.currentParticipant.active = false
          else
            for subjectIDAndBlankness in nextSubjectIDs
              [subjectID, blankness] = subjectIDAndBlankness.split(":")
              if blankness=="blank"
                source = Experiments.SOURCE_BLANK
              else
                source = Experiments.SOURCE_NON_BLANK
              do (subjectID) =>
                if subjectID == "RANDOM"
                  backgroundFetcher.then =>
                    @fetch(1)
                    .then (subject) =>
                      if subject?
                        Experiments.sources[subject[0].zooniverseId]=Experiments.SOURCE_RANDOM
                else
                  backgroundFetcher.then =>
                    @subjectFetch(subjectID)
                    .then (subject) =>
                      if subject?
                        Experiments.sources[subjectID]=source
      .fail =>
        AnalyticsLogger.logError "500", "Couldn't load next experimental subjects", "error"
    else
      backgroundFetcher = new $.Deferred
      backgroundFetcher.resolve null
    backgroundFetcher.promise()

  # mark subject as seen in experiment server, and remove any "used" subjects from our queue.
  @markAsSeen: (subjectID) ->
    seenNotifier = new $.Deferred
    try
      if Experiments.sources[subjectID]==Experiments.SOURCE_INSERTED
        url = Experiments.EXPERIMENT_SERVER_URL + 'experiment/' + Experiments.ACTIVE_EXPERIMENT + '/participant/' + Geordi.UserGetter.currentUserID + '/insertion/' + subjectID
      else if Experiments.sources[subjectID]==Experiments.SOURCE_RANDOM
        url = Experiments.EXPERIMENT_SERVER_URL + 'experiment/' + Experiments.ACTIVE_EXPERIMENT + '/participant/' + Geordi.UserGetter.currentUserID + '/random'
      if Experiments.sources[subjectID]==Experiments.SOURCE_BLANK || Experiments.sources[subjectID]==Experiments.SOURCE_NON_BLANK
        url = Experiments.EXPERIMENT_SERVER_URL + 'experiment/' + Experiments.ACTIVE_EXPERIMENT + '/participant/' + Geordi.UserGetter.currentUserID + '/' + subjectID
      else if Experiments.sources[subjectID]==Experiments.SOURCE_RANDOM
        url = Experiments.EXPERIMENT_SERVER_URL + 'experiment/' + Experiments.ACTIVE_EXPERIMENT + '/participant/' + Geordi.UserGetter.currentUserID + '/random'
      else
        AnalyticsLogger.logError "409", "Couldn't POST subject "+subjectID+" to mark as seen", "error"
        return null
      $.post(url)
      .then (participant) =>
        Experiments.currentParticipant = participant
        # ensure any previously seen subjects by this participant are removed from the queue if present.
        for queue in [Experiments.currentParticipant.blank_subjects_seen,Experiments.currentParticipant.non_blank_subjects_seen]
          for seenID in queue
            for queuedSubject of ExperimentalSubject.all
              if seenID==queuedSubject.zooniverseId
                ExperimentalSubject.where(zooniverseId: seenID).delete
        seenNotifier.resolve participant
      .fail =>
        AnalyticsLogger.logError "500", "Couldn't POST subject "+subjectID+" to mark as seen", "error"
        seenNotifier.resolve null
    catch error
      AnalyticsLogger.logError "500", "Couldn't POST subject "+subjectID+" to mark as seen", "error"
      seenNotifier.resolve null
    seenNotifier.promise()

  # get the next subject IDs for the specified user ID from the experiment server	(assumes "interesting" cohort)
  @getNextSubjectIDs: (numberOfSubjects) ->
    subjectIDsFetcher = new $.Deferred
    try
      $.get(Experiments.EXPERIMENT_SERVER_URL + 'experiment/' + Experiments.ACTIVE_EXPERIMENT + '/participant/' + Geordi.UserGetter.currentUserID + '/next/' + numberOfSubjects)
      .then (data) =>
        subjectIDsFetcher.resolve data
      .fail =>
        AnalyticsLogger.logError "500", "Couldn't retrieve next subjects", "error"
        subjectIDsFetcher.resolve null
    catch error
      AnalyticsLogger.logError "500", "Couldn't GET next subjects", "error"
      subjectIDsFetcher.resolve null
    subjectIDsFetcher.promise()

  # for experimental cohort users, determine next subjects accordingly
  @next: (callback) =>
    if Experiments.ACTIVE_EXPERIMENT == "SerengetiBlanksExperiment1"
      @current.destroy() if @current?
      count = @count()

      # If empty, try to prepare one random "current" quickly
      if count == 0
        fetcher = @fetch 1

      # for experimental cohort, load up the right subjects
      Experiments.getParticipant()
      .then (participant) =>
        if participant?
          Experiments.currentParticipant = participant
          #Experiments.currentCohort = participant.cohort
          toFetch = (@queueLength - @count()) + 1
          if Experiments.currentParticipant.active && Experiments.currentCohort != Experiments.COHORT_CONTROL && Experiments.currentCohort != Experiments.COHORT_INELIGIBLE
            @loadMoreRandomSubjects toFetch
          else
            # Fill the rest of the queue in the background according to the experiment server's instructions
            @loadMoreExperimentalSubjects toFetch

      # background work kicked off if needed, now we can advance
      if fetcher is null
        fakeFetcher = new $.Deferred
        fetcher = fakeFetcher
      @advance fetcher, callback
      if fakeFetcher?
        fakeFetcher.resolve()
    else
      # InterestingAnimals experiment not running - revert to parent
      super callback

module.exports = ExperimentalSubject
