This is a script written by AI to test for AES-NI crypto acceleration for your machine.
Please be aware to rule out significant performance variation due to CPU stepping.  Each test will attempt to detect the frequency at the beginning of the test.
For a clean test, disable stepping and force to the highest frequency on OSes permitting.

Usage:  [PIN=N] [sudo] sh ssh-aesni.sh
          PIN=N  pin the benchmark to core N (default: last core). sudo needed on Apple Silicon for live frequency via powermetrics.
