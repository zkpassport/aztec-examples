export interface Market {
  id: string
  category: string
  question: string
  /** Price of a YES share, in cents */
  yes: number
  volume: string
  closes: string
}

export const MARKETS: Market[] = [
  {
    id: "eth-5k",
    category: "Crypto",
    question: "Will ETH close above $5,000 on 31 December 2026?",
    yes: 34,
    volume: "$1.2M",
    closes: "31 Dec 2026",
  },
  {
    id: "aztec-tx",
    category: "Crypto",
    question: "Will Aztec process 1M transactions in December 2026?",
    yes: 61,
    volume: "$318K",
    closes: "1 Jan 2027",
  },
  {
    id: "final-penalties",
    category: "Sports",
    question: "Will the 2027 Champions League final go to penalties?",
    yes: 18,
    volume: "$842K",
    closes: "5 Jun 2027",
  },
  {
    id: "ba-snow",
    category: "Weather",
    question: "Will it snow in Buenos Aires city in 2027?",
    yes: 7,
    volume: "$96K",
    closes: "31 Dec 2027",
  },
]
