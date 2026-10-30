// Fake Anthropic Messages endpoint. Replies with the arrival epoch (ms) as the text.
import http from "node:http";
const ev = (e, d) => `event: ${e}\ndata: ${JSON.stringify(d)}\n\n`;
http.createServer((req, res) => {
  const arrived = performance.timeOrigin + performance.now();
  req.resume(); req.on("end", () => {
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.end(
      ev("message_start", { type: "message_start", message: { id: "m", type: "message", role: "assistant", model: "claude-fable-5", content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 1, output_tokens: 1 } } }) +
      ev("content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }) +
      ev("content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: String(arrived) } }) +
      ev("content_block_stop", { type: "content_block_stop", index: 0 }) +
      ev("message_delta", { type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: null }, usage: { output_tokens: 1 } }) +
      ev("message_stop", { type: "message_stop" }));
  });
}).listen(8787, "127.0.0.1", () => console.log("mock on 8787"));
