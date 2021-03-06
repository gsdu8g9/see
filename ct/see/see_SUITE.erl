-module(see_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([integration_test/1]).
 
all() -> [integration_test].
 
init_per_suite(Config) ->
    start_see(),
    DataDir = proplists:get_value(data_dir, Config),
    Port = integer_to_binary(start_webserver_mock(DataDir)),
    URL = <<"http://localhost:", Port/binary>>,
    index_pages(URL),
    [{url, URL} | Config].

end_per_suite(Config) ->
    application:stop(see_crawler),
    application:stop(see_db),
    webserver_mock:stop(),
    Config.

start_webserver_mock(DataDir) ->
    WebserverOptions = [{link, false}, {ip, {0, 0, 0, 0}},
                        {port, 0}, {data_dir, DataDir},
                        {test_pid, self()}],
    {ok, ServerPid} = webserver_mock:start(WebserverOptions),
    unlink(ServerPid),
    mochiweb_socket_server:get(ServerPid, port).

start_see() ->
    application:set_env(see_crawler, db_node, node(), [{persistent, true}]),
    application:set_env(see_db, domain_filter, "^localhost:[0-9]+", [{persistent, true}]),
    {ok, _} = application:ensure_all_started(see_db),
    {ok, _} = application:ensure_all_started(see_crawler).

index_pages(URL) ->
    ok = see_db_srv:queue(URL),
    wait_for_indexing().

wait_for_indexing() ->
    receive
        {request, _} ->
            wait_for_indexing()
    after
        1000 ->
            ok
    end.

assert_search_result(RootURL, Phrase, Pages) ->
    Results = lists:sort([{<<RootURL/binary, Path/binary>>, Title} || {Path, Title} <- Pages]),
    Results = lists:sort(see_db_srv:search(Phrase)).

integration_test(Config) ->
    URL = proplists:get_value(url, Config),

    Index = {<<"/">>, []},
    ChopinPage = {<<"/Frederic+Chopin.txt">>, []},
    LisztPage = {<<"/Franz+Liszt.txt">>, []},
    TuringPage = {<<"/Alan+Turing.html">>, [<<"Wikipedia - Alan Turing">>]},

    assert_search_result(URL, <<"Chopin">>, [Index, ChopinPage, LisztPage]),
    assert_search_result(URL, <<"Żelazowa Wola"/utf8>>, [ChopinPage]),
    assert_search_result(URL, <<"Alan Turing enigma">>, [TuringPage]),
    assert_search_result(URL, <<"Alan Turing">>, [Index, TuringPage]).
