// The echo tool (ABS-97): answers each agent's call with what it sent.
AbstractPlugin.tools.handle("echo", (input) => {
  if (typeof input.text !== "string") throw new Error("Send some text to echo.");
  return "Echo: " + input.text;
});
