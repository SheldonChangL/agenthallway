// Command agenthallway-mcp exposes one Agent Hallway session to the agent that launches
// it, over stdio.
//
// It is started by the agent as a child process, so it must be told which
// session it acts for. See -as.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"

	"agenthub.local/agenthub/internal/mcpserver"
	"agenthub.local/agenthub/internal/product"
)

func main() {
	if err := run(); err != nil {
		// stdout is the MCP transport; diagnostics must not go near it.
		fmt.Fprintf(os.Stderr, "agenthallway-mcp: %v\n", err)
		os.Exit(1)
	}
}

// defaultNodeURL is where the server looks for the node when -url is not given:
// AGENTHALLWAY_URL, else the older AGENTHUB_URL, else the loopback default.
func defaultNodeURL() string {
	if given := product.Getenv("URL"); given != "" {
		return given
	}
	return "http://127.0.0.1:7462"
}

func run() error {
	nodeURL := flag.String("url", defaultNodeURL(), "Agent Hallway node URL")
	as := flag.String("as", "",
		"the session this server acts for, as <provider>:<id> (required)")
	channel := flag.Bool("channel", false,
		"push messages for this session into the agent as they arrive, instead of waiting "+
			"to be asked. Claude Code only, and it needs the session's autoWake open on the "+
			"node and channels enabled for your organisation")
	flag.Parse()

	// Anything written to stdout would be read as a protocol frame.
	log.SetOutput(os.Stderr)

	client, err := mcpserver.NewClient(*nodeURL)
	if err != nil {
		return err
	}

	ctx := context.Background()
	binding, err := mcpserver.Bind(ctx, client, *as)
	if err != nil {
		if errors.Is(err, mcpserver.ErrNoBinding) {
			// Said at length because the obvious alternative — letting the
			// caller name a session per call — is exactly what must not happen:
			// every agent on this machine can reach this same node.
			return errors.New(
				"-as is required: this server acts for exactly one session, and MCP does not\n" +
					"say which session called it, so it cannot be inferred. Start it as\n" +
					"  agenthallway-mcp -as codex:<id>\n" +
					"and run one server per session you want to expose")
		}
		return err
	}

	nodeID, err := client.NodeID(ctx)
	if err != nil {
		return err
	}
	options := []mcpserver.Option{}
	if *channel {
		options = append(options, mcpserver.WithChannel())
	}
	server, err := mcpserver.New(client, binding, nodeID, options...)
	if err != nil {
		return err
	}
	return server.Run(ctx)
}
