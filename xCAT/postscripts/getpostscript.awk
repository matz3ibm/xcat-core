#!/usr/bin/awk -f
BEGIN {
        server = "openssl s_client -quiet -connect " ENVIRON["XCATSERVER"] " 2> /dev/null"


        quit = "no"


        print "<xcatrequest>" |& server
        print "   <command>getpostscript</command>" |& server
        print "</xcatrequest>" |& server

        while (server |& getline) {
                print $0
                if (match($0,"<serverdone>")) {
                  quit = "yes"
                }
                if (match($0,"</xcatresponse>") && match(quit,"yes")) {
                  close(server)
                  exit
               }
        }
}
