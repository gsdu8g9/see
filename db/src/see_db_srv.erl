-module(see_db_srv).
-behaviour(gen_server).

-export([start/0,
         start_link/0,
         stop/0,
         visited/2,
         queue/1,
         next/0,
         search/1]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(page, {id, url, words, last_visit = erlang:timestamp()}).
-record(index, {word, pages}).

start() ->
    gen_server:start({local, ?MODULE}, ?MODULE, [], []).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
    gen_server:call(?MODULE, stop).

visited(URL, Words) ->
    gen_server:cast(?MODULE, {visited, URL, Words}).

queue(URL) ->
    gen_server:call(?MODULE, {queue, URL}).

next() ->
    gen_server:call(?MODULE, next).

search(Phrases) when is_binary(Phrases) ->
    gen_server:call(?MODULE, {search, Phrases}).

%----------------------------------------------------------

init(_Args) ->
    ets:new(see_pages, [named_table, {keypos, #page.id}]),
    ets:new(see_index, [named_table, {keypos, #index.word}]),
    {ok, []}.

terminate(_, _) ->
    ok.

handle_cast({visited, URL, {error, Reason}}, State) ->
    Id = erlang:phash2(URL),
    remove_from_index(Id),
    ets:insert(see_pages, #page{id = Id, url = URL, words = {error, Reason}}),
    {noreply, State};

handle_cast({visited, URL, binary}, State) ->
    Id = erlang:phash2(URL),
    remove_from_index(Id),
    ets:insert(see_pages, #page{id = Id, url = URL, words = binary}),
    {noreply, State};

handle_cast({visited, URL, {redirect, RedirectURL}}, State) ->
    Id = erlang:phash2(URL),
    remove_from_index(Id),
    ets:insert(see_pages, #page{id = Id, url = URL, words = {redirect, RedirectURL}}),
    {noreply, State};

handle_cast({visited, URL, RawWords}, State) ->
    Id = erlang:phash2(URL),
    remove_from_index(Id),
    Words = process_words(RawWords),
    ets:insert(see_pages, #page{id = Id, url = URL, words = Words}),
    lists:foreach(fun(Word) -> insert_to_index(Word, Id) end, Words),
    {noreply, State};

handle_cast(_, State) ->
    {noreply, State}.

handle_call(stop, _, State) ->
    {stop, shutdown, ok, State};

handle_call({queue, URL}, _, State) ->
    case sanitize_url(URL) of
        {ok, SanitizedURL} ->
            queue_url(SanitizedURL),
            {reply, ok, State};
        error ->
            {reply, error, State}
    end;

handle_call(next, _, State) ->
    case ets:match(see_pages, #page{last_visit = null, url = '$1', _ = '_'}, 1) of
        {[[URL]], _} ->
            {reply, {ok, URL}, State};
        _ ->
            {reply, nothing, State}
    end;

handle_call({search, Phrases}, _, State) ->
    Words = process_words(binary:split(Phrases, <<" ">>, [global, trim_all])),
    PageLists = [get_pages(Word) || Word <- Words],
    Result = merge_page_lists(PageLists),
    {reply, [get_url(Id) || Id <- Result], State};

handle_call(_, _, State) ->
    {noreply, State}.

handle_info(_, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _) ->
    {ok, State}.

%----------------------------------------------------------

sanitize_url(URL) ->
    case mochiweb_util:urlsplit(URL) of
        {[], _, _, _, _} ->
            error;
        {Scheme, Netloc, [], Query, _} ->
            {ok, mochiweb_util:urlunsplit({Scheme, Netloc, "/", Query, []})};
        {Scheme, Netloc, Path, Query, _} ->
            {ok, mochiweb_util:urlunsplit({Scheme, Netloc, Path, Query, []})}
    end.

queue_url(URL) ->
    Id = erlang:phash2(URL),
    case ets:lookup(see_pages, Id) of
        [] ->
            ets:insert(see_pages, #page{id = Id, url = URL, last_visit = null});
        _ ->
            ok
    end.

remove_from_index(Id) ->
    case ets:lookup(see_pages, Id) of
        [#page{words = Words}] when is_list(Words) ->
            lists:foreach(fun(Word) -> remove_from_word(Word, Id) end, Words);
        _Other ->
            ok
    end.

remove_from_word(Word, Id) ->
    case ets:lookup(see_index, Word) of
        [] ->
            ok;
        [#index{pages = Pages}] ->
            ets:insert(see_index, #index{word = Word, pages = sets:del_element(Id, Pages)})
    end.

insert_to_index(Word, Id) ->
    case ets:lookup(see_index, Word) of
        [#index{pages = Pages}] ->
            ets:insert(see_index, #index{word = Word, pages = sets:add_element(Id, Pages)});
        [] ->
            ets:insert(see_index, #index{word = Word, pages = sets:from_list([Id])})
    end.

get_url(Id) ->
    [#page{url = URL}] = ets:lookup(see_pages, Id),
    URL.

get_pages(Word) ->
    case ets:lookup(see_index, Word) of
        [] ->
            sets:new();
        [#index{pages = Pages}] ->
            Pages
    end.

merge_page_lists([]) ->
    [];

merge_page_lists(PageLists) ->
    sets:to_list(sets:intersection(PageLists)).

process_words(RawWords) ->
    lists:filtermap(fun process_word/1, RawWords).

process_word(Word) ->
    try
        {true, unistring:to_lower(Word)}
    catch
        _:_ ->
            false
    end.

