---
title: "Brainstorming Key Problems of the App"
status: "Historical — unfiltered early notes. See `revised_brainstorming.md` for the cleaned-up version and `docs/overview.md` for current architecture."
---

# Problem 1 - Dealing with Past Shifts

I think the way to do this is to be very flexible with the main editing system / deletion system with past shifts,
but to keep a minimally detailed changelog such that every commit and every past state is restorable.

Then I can remove restrictions on changing past shift information and editing it. Don't need distinction between past and current shifts
in terms of editability, including deletion. 

Do need a distinction in terms of generation  because it relies on availability mappings, which currently are just for the next week. How do 
I make this easier and more customizable / workable? Users now shouldn't be restricted to only being able to generate and store availabilities for the 
following week.

- changelog
    - per week? I think per week is the best, with the default changelog view being a per-week affair, while there also exists
    a total changelog view which shows every week, just sorted by the date committed. 
    - How do I keep the changelog? diffs? 
        - then restoration is just an assembly of the diffs starting from a base commit - doesn't need to be diffs based on json or code, small custom diff language for shifts etc.
        - what does that look like? -> what's editable? 
            1. shift addition / deletion 
            2. employee assignment to shift

    - when do I compress? good defaults should ensure good performance - will need to see how much this can affect performance.

    - grid view of diff history would be good - landscape fill screen view. This would actually be good for the main weekly rota as a feature,
    easy view or something to see the week's shifts in one non-scrolling static screen. Use it to show diffs, allow shifts to be clickable to
    see specific history.

- commits
    - don't need commit distinction on past vs current vs future shifts
    - at least don't need to save this on the commit - is easily calculable 

# Problem 2 - Availability Mappings: Storage, Generation

- Availability Mapping:
    - use cases:
        - manager creating rota for 1 week / 1 month / next 2 weeks for example. 
            - necessitates allowing setting availability for a variable amount of time
            - minimum unit of mapping could be either 1 week or 1 day 
            - probably 1 week minimum unit 

- rota could use a feature to reassemble single day shifts and also "rest of the week" shifts

- should be some sort of highlighting for the current day and current shifts active

- employee page still kind of buggy, need to unify the title cards and stuff

question - do I need to store past week availabilities? Ties hand in hand with ability to generate past shifts
answer: don't think so, current system just allowing "building" a past shift but without smart generation is good. With more template options like weekly or daily
becomes even easier.

already have existing per-employee availability "template" which is used for the next week availability, just called "default" instead of template.

future availabilities work hand in hand with overrides, 

# History vs Logging Page

Do I even need a history page? or should it just be a logging page, leaving history to the actual rota view?

# Should have templates that aren't just shifts, but also weekly templates with employee assignments, and also day templates that can be used.

Rota building should feel like "building". "Constructing". Should have quite a few tools, and the rota should feel malleable, but also
the default generation should feel like always one of the best options.

question - how to make this sandboxy feel on iphone portrait mode?? Should the focus on iphone just be very very smart defaults?

Generation algorithm now needs to be a bit more complex if I add day templates and weekly templates, as these would have to be "pinned"

Do I even need this for this app, or for this iteration of the app?

daily templates would be something the user could just add to a day (drag, tap?) when building a rota.

# Needs Revision, Polishing

- employee list page, unity across pages in terms of formatting
- overrides handling for date ranges. Unintuitive and tedious at the moment.

# Additional Features

- assigning employees to apple / whatsapp contacts to allow bulk messaging
- figuring out a way to smartly allow employees to send their availability as compact data format such that the app can read it. Turns this app
into an actual "system", still without a database.
    - availability is actually a very compressable type of data - lots of space adjacent repetition. Has the potential to be a very light transfer.
- Need to eventually figure out how to export and import the total database to allow for transferring data.
- Need easy switching between different businesses / different shops

# Note on MLMs

- Stress on data storage and readability - allow this to easily be read and comprehended by an MLM
- New stress on data security to reduce possiblity of model poisoning, prompt injection 
    - _notes_ section especially on employee pages

# Note on Usability and Complexity

- Need to have both a stronger induction process into the app, less jargon, more intuitive interfaces
    - use "save" instead of "commit"
- Great defaults, concise and navigable help page. Maximum disclosure on motivation, intuition, intention.
- Manager more likely to buy it if it means easy transition from previous system
    - more likely to buy it if it seems easier for them drastically, even on setup
    - if it seems easier for employees as well.






