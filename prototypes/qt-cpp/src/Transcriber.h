#pragma once
#include <string>
#include <vector>

// French speech-to-text with word timestamps (whisper.cpp, Metal backend).
struct Word { std::string text; double t0, t1; };
struct SttResult {
    bool ok = false;
    double audioSeconds = 0, processSeconds = 0, loadSeconds = 0;
    double rtf = 0, wer = -1;
    std::string text, error;
    std::vector<Word> words;
};

SttResult runTranscription(const std::string &wavPath, const std::string &modelPath, const std::string &referenceTextPath);
double wordErrorRate(const std::string &reference, const std::string &hypothesis);
